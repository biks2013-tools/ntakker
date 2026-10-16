// NtakkerCore/Transcription/Providers/AppleSpeechTranscriptionProvider.swift —
// see docs/design/plan-005-apple-speech-streaming.md §"Phase D".
//
// Phase D (plan-005) — `TranscriptionProvider` conformer that drives one
// `SpeechAnalyzerAdapter` per active locale and reconciles their finals
// into a single stream of `StreamingTranscriptionEvent`s.
//
// Two types live in this file:
//
//   * `AppleSpeechTranscriptionProvider` — the public, factory-style
//     provider. Resolves the locale list from `TranscriptionOptions.languageHints`
//     (defaulting to `[Locale.current]` when the caller passes an empty list),
//     gates session opening behind `SpeechPermission.ensureGranted()`, and
//     constructs one `SpeechAnalyzerAdapter` per locale via the injected
//     factory. Default factory is `ProductionSpeechAnalyzerAdapter.make(_:)`;
//     tests inject `MockSpeechAnalyzer`.
//
//   * `AppleSpeechSession` — the per-recording streaming session. Owns the
//     locale-keyed analyzer pool, fans `ingest(_:)` out to every adapter,
//     consumes per-adapter `TranscriptionResult` streams, surfaces volatile
//     partials immediately, and reconciles per-utterance finals across all
//     locales (highest-confidence wins) before emitting a single `final`
//     event into the public `events` stream.
//
// Reconciliation invariants (rewritten 2026-10-16, EVAL-2026-10-16 TR-5 —
// the earlier per-locale utterance ids never matched, so both languages'
// finals were always emitted):
//
//   * All locales hear the same audio, so they share ONE open utterance
//     group (`openGroupId`). Partials from any locale are emitted under it,
//     and the reconciled final reuses that id, replacing the partial row.
//     A partial from a locale that already delivered its final for the open
//     group starts the next group.
//   * A final joins, in order of preference: the oldest pending (not open)
//     group that lacks this locale's final and whose time range overlaps
//     (or either range is unknown); else the open group if it lacks this
//     locale's final; else a new group.
//   * A group reconciles as soon as every analyzer delivered a final, or
//     `reconciliationWindowMs` after its first final. The highest
//     confidence wins and ONE `.final` is emitted.
//   * A final that arrives after its group reconciled and overlaps that
//     group's time range is a straggler and is dropped instead of being
//     emitted as a second-language duplicate.
//   * `reconciledUtteranceIds` keeps the timeout path a no-op once the
//     all-locales path fired.
//
// An `NSLock` guards the mutable grouping state so the per-locale drain
// `Task`s and the timeout `Task`s do not race.

import Foundation
import Logging
import Speech

/// `TranscriptionProvider` backed by Apple's on-device
/// `SpeechAnalyzer + SpeechTranscriber`. Streaming-only — `transcribe(...)`
/// is implemented as a thin adapter over `openStreamingSession(...)` so the
/// existing batch-shaped callers (Phase E pipeline) keep working.
@available(macOS 26.0, *)
public actor AppleSpeechTranscriptionProvider: TranscriptionProvider {
    public nonisolated let id = "apple"
    public nonisolated let displayName = "Apple Speech (on-device)"
    public nonisolated let supportedModes: Set<TranscriptionMode> = [.streaming]

    private let logger: Logger
    private let analyzerFactory: @Sendable (Locale) throws -> any SpeechAnalyzerAdapter

    public init(
        logger: Logger = Logger(label: "ntakker-cli.transcription.apple"),
        analyzerFactory: (@Sendable (Locale) throws -> any SpeechAnalyzerAdapter)? = nil
    ) {
        self.logger = logger
        if let analyzerFactory {
            self.analyzerFactory = analyzerFactory
        } else {
            // Default factory captures the provider's logger so the
            // adapter's internal Tasks can log asset-install / analyzer-
            // start failures into the same log file the rest of ntakker
            // writes to (`~/.tool-agents/ntakker/ntakker.log`).
            let captured = logger
            self.analyzerFactory = { locale in
                try ProductionSpeechAnalyzerAdapter.make(locale, logger: captured)
            }
        }
    }

    public func openStreamingSession(
        source: SourceTag, options: TranscriptionOptions
    ) async throws -> any StreamingTranscriptionSession {
        // Step 1 — resolve the requested locale list. When no hint was
        // passed we fall back to `Locale.current`, but `Locale.current`
        // on macOS may carry regional-override extensions like
        // `en_US@rg=grzzzz` (BCP-47 `-u-rg-grzzzz`) that
        // `SFSpeechRecognizer.supportedLocales()` rejects. Step 2
        // canonicalises every entry to the bare `<lang>-<region>` form
        // before validation so the user gets the expected `en-US` model.
        let rawLocales = options.languageHints.isEmpty
            ? [Locale.current]
            : options.languageHints.map { Locale(identifier: $0) }

        let canonicalLocales = rawLocales.map { Self.canonicalize($0) }

        // Step 2 — validate every canonical locale against the on-device
        // supported set. We use `SFSpeechRecognizer.supportedLocales()`
        // because (a) it ships in every macOS the project supports and
        // (b) the underlying installable model set is the same one
        // `SpeechTranscriber` consumes. An unsupported locale is a
        // configuration error: throw a `transcriptionConfigConflict`
        // so the streaming pipeline surfaces a `.error(detail:)` event
        // and the UI banner tells the user what to do (set
        // `NTAKKER_TRANSCRIBE_LANGUAGE` to a supported value).
        let supportedSet = Set(SFSpeechRecognizer.supportedLocales().map { $0.identifier })
        for (raw, canonical) in zip(rawLocales, canonicalLocales) {
            guard supportedSet.contains(canonical.identifier) else {
                let preview = supportedSet.sorted().prefix(20).joined(separator: ", ")
                let hintNote = (raw.identifier == canonical.identifier)
                    ? "locale '\(raw.identifier)'"
                    : "locale '\(raw.identifier)' (canonicalised to '\(canonical.identifier)')"
                throw NtakkerError.transcriptionConfigConflict(
                    reason: "Apple Speech: \(hintNote) is not in the on-device supported set on this Mac. Set NTAKKER_TRANSCRIBE_LANGUAGE to a supported value (e.g. 'en-US' or 'el-GR') in ~/.tool-agents/ntakker/.env. First few supported: \(preview)…"
                )
            }
        }

        try await SpeechPermission.ensureGranted()

        let localeList = canonicalLocales.map { $0.identifier }.joined(separator: ",")
        logger.info(
            "Apple Speech: opening streaming session source=\(source) locales=\(localeList)"
        )

        var localeAnalyzers: [(Locale, any SpeechAnalyzerAdapter)] = []
        for locale in canonicalLocales {
            let adapter = try analyzerFactory(locale)
            localeAnalyzers.append((locale, adapter))
        }

        return AppleSpeechSession(
            analyzers: localeAnalyzers,
            source: source,
            logger: logger
        )
    }

    /// Reduce a `Locale` to its bare `<lang>-<region>` form, dropping
    /// regional-override extensions (`@rg=grzzzz` / BCP-47 `-u-rg-…`)
    /// that `SFSpeechRecognizer.supportedLocales()` does not
    /// recognise. When a locale lacks either a language code or a
    /// region the original is returned verbatim so the validation step
    /// can produce a clear "unsupported" error from it.
    ///
    /// Implementation note — must use `locale.language.region`, not
    /// `locale.region`. The latter returns the regional **override**
    /// (the `GR` in `en_US@rg=grzzzz` — a formatting-only hint), which
    /// for users who set "Region" to a different country than their
    /// "Language" produces a wrong canonicalisation (e.g. `en-GR`).
    /// `Locale.Language.region` returns the language's intrinsic region
    /// (`US` in the same example), which is the value the supported-
    /// locale set actually keys on. Verified empirically by
    /// `test_scripts/probe-locale-canonicalize.swift`.
    static func canonicalize(_ locale: Locale) -> Locale {
        guard
            let lang = locale.language.languageCode?.identifier,
            let region = locale.language.region?.identifier
        else {
            return locale
        }
        return Locale(identifier: "\(lang)-\(region)")
    }

    public func transcribe(
        samples: [Float], source: SourceTag, options: TranscriptionOptions
    ) async throws -> String {
        let session = try await openStreamingSession(source: source, options: options)
        await session.ingest(samples)
        await session.finish()
        var collected = ""
        for await event in session.events {
            if case .final(_, let text, _, _, _, _) = event {
                collected += (collected.isEmpty ? "" : " ") + text
            }
        }
        return collected
    }
}

/// Per-recording dual-locale streaming session. Owns the analyzer pool and
/// reconciles per-utterance finals across locales. See file-header comment
/// for the full reconciliation invariants.
///
/// `@unchecked Sendable` because `NSLock` provides the synchronisation the
/// compiler can't prove on its own (mirrors `MockSpeechAnalyzer` and
/// `ProductionSpeechAnalyzerAdapter`).
@available(macOS 26.0, *)
final class AppleSpeechSession: StreamingTranscriptionSession, @unchecked Sendable {
    /// Maximum wait-for-stragglers window after the first per-utterance
    /// final lands, in milliseconds. After this elapses, `reconcile(_:)`
    /// fires with whichever finals it has.
    public static let reconciliationWindowMs: Int = 400

    private let analyzers: [(locale: Locale, adapter: any SpeechAnalyzerAdapter)]
    private let source: SourceTag
    private let logger: Logger
    private let eventsContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation
    public let events: AsyncStream<StreamingTranscriptionEvent>

    private let lock = NSLock()
    /// F20 (EVAL 2026-06-12): the per-adapter result-forwarding tasks,
    /// stored so `finish()` can await them. Populated once in `init`
    /// and never mutated afterwards — no lock needed.
    private var forwardingTasks: [Task<Void, Never>] = []
    private var nextUtteranceCounter: Int = 0
    /// The utterance group all locales' partials currently feed (TR-5).
    private var openGroupId: Int?
    /// Finals collected per group, awaiting reconciliation.
    private var pendingFinals: [Int: [(locale: Locale, result: TranscriptionResult)]] = [:]
    private var reconciledUtteranceIds: Set<Int> = []
    /// Time ranges of the most recently reconciled groups, used to drop
    /// late stragglers (bounded to the last few).
    private var recentReconciledRanges: [ClosedRange<Date>] = []

    init(
        analyzers: [(Locale, any SpeechAnalyzerAdapter)],
        source: SourceTag,
        logger: Logger
    ) {
        self.analyzers = analyzers
        self.source = source
        self.logger = logger
        let (s, c) = AsyncStream.makeStream(
            of: StreamingTranscriptionEvent.self,
            bufferingPolicy: .bufferingNewest(128))
        self.events = s
        self.eventsContinuation = c

        for (locale, adapter) in analyzers {
            forwardingTasks.append(Task { [weak self] in
                for await result in adapter.results {
                    self?.handle(result, from: locale)
                }
            })
        }
    }

    func ingest(_ samples: [Float]) async {
        for (_, adapter) in analyzers {
            await adapter.ingest(samples)
        }
    }

    func finish() async {
        for (_, adapter) in analyzers {
            await adapter.finalizeAndFinish()
        }
        // F20 (EVAL 2026-06-12): `finalizeAndFinish()` drains the
        // ANALYZER, but the last results may still sit in the adapter's
        // results stream waiting for the forwarding task to consume
        // them. Await the forwarders (their streams are now guaranteed
        // to end) BEFORE reconciling, so the final utterance is not
        // dropped from the public stream and the sidecar.
        for task in forwardingTasks {
            await task.value
        }
        // Drain any pending finals (window may not have fired yet).
        let pendingIds: [Int] = {
            lock.lock(); defer { lock.unlock() }
            return Array(pendingFinals.keys)
        }()
        for id in pendingIds { reconcile(id) }
        eventsContinuation.finish()
    }

    // MARK: - Private

    private func handle(_ result: TranscriptionResult, from locale: Locale) {
        if !result.isFinal {
            let groupId = openGroupForPartial(from: locale)
            eventsContinuation.yield(
                .partial(
                    utteranceId: Self.utteranceIdToUUID(groupId),
                    text: result.text,
                    confidence: result.confidence,
                    speaker: nil
                )
            )
            return
        }

        lock.lock()
        if let range = result.timeRange,
           recentReconciledRanges.contains(where: { Self.overlaps($0, range) }) {
            lock.unlock()
            logger.debug("apple-speech: dropping late \(locale.identifier) final for an already reconciled utterance")
            return
        }
        let groupId = groupForFinal(result, from: locale)
        var arr = pendingFinals[groupId] ?? []
        arr.append((locale, result))
        pendingFinals[groupId] = arr
        let collected = arr.count
        lock.unlock()

        if collected == analyzers.count {
            reconcile(groupId)
        } else if collected == 1 {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Self.reconciliationWindowMs))
                self?.reconcile(groupId)
            }
        }
    }

    /// The group a partial from `locale` belongs to.
    private func openGroupForPartial(from locale: Locale) -> Int {
        lock.lock(); defer { lock.unlock() }
        if let open = openGroupId,
           !(pendingFinals[open] ?? []).contains(where: { $0.locale == locale }) {
            return open
        }
        // No open group, or this locale already finished it: the partial
        // starts the next utterance. The previous open group (if any)
        // stays pending until its stragglers arrive or the window fires.
        let id = nextUtteranceCounter
        nextUtteranceCounter += 1
        openGroupId = id
        return id
    }

    /// The group a final from `locale` joins. Caller holds `lock`.
    private func groupForFinal(_ result: TranscriptionResult, from locale: Locale) -> Int {
        let candidates = pendingFinals
            .filter { id, finals in
                id != openGroupId
                    && !reconciledUtteranceIds.contains(id)
                    && !finals.contains(where: { $0.locale == locale })
                    && finals.allSatisfy { other in
                        guard let a = other.result.timeRange, let b = result.timeRange else { return true }
                        return Self.overlaps(a, b)
                    }
            }
            .keys
            .sorted()
        if let oldest = candidates.first { return oldest }
        if let open = openGroupId,
           !(pendingFinals[open] ?? []).contains(where: { $0.locale == locale }) {
            return open
        }
        let id = nextUtteranceCounter
        nextUtteranceCounter += 1
        return id
    }

    /// Same spoken span: the ranges overlap by more than half of the
    /// shorter one. Back-to-back utterances that merely touch at the
    /// boundary do not match. Zero-length ranges fall back to a plain
    /// intersection test.
    static func overlaps(_ a: ClosedRange<Date>, _ b: ClosedRange<Date>) -> Bool {
        let lo = max(a.lowerBound, b.lowerBound)
        let hi = min(a.upperBound, b.upperBound)
        guard lo <= hi else { return false }
        let shorter = min(a.upperBound.timeIntervalSince(a.lowerBound),
                          b.upperBound.timeIntervalSince(b.lowerBound))
        guard shorter > 0 else { return true }
        return hi.timeIntervalSince(lo) > shorter / 2
    }

    private func reconcile(_ utteranceId: Int) {
        let arr: [(locale: Locale, result: TranscriptionResult)]
        lock.lock()
        if reconciledUtteranceIds.contains(utteranceId) {
            lock.unlock()
            return
        }
        guard let pending = pendingFinals.removeValue(forKey: utteranceId) else {
            lock.unlock()
            return
        }
        arr = pending
        reconciledUtteranceIds.insert(utteranceId)
        if openGroupId == utteranceId { openGroupId = nil }
        let ranges = arr.compactMap(\.result.timeRange)
        if let lo = ranges.map(\.lowerBound).min(), let hi = ranges.map(\.upperBound).max() {
            recentReconciledRanges.append(lo...hi)
            if recentReconciledRanges.count > 8 { recentReconciledRanges.removeFirst() }
        }
        lock.unlock()

        let winner = arr.max { (a, b) in
            (a.result.confidence ?? 0) < (b.result.confidence ?? 0)
        }!
        let range: ClosedRange<Date> = winner.result.timeRange ?? (Date()...Date())
        eventsContinuation.yield(
            .final(
                utteranceId: Self.utteranceIdToUUID(utteranceId),
                text: winner.result.text,
                confidence: winner.result.confidence,
                range: range,
                language: winner.locale.identifier,
                speaker: nil
            )
        )
    }

    private static func utteranceIdToUUID(_ i: Int) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = UInt8(truncatingIfNeeded: (i >> 24) & 0xff)
        bytes[1] = UInt8(truncatingIfNeeded: (i >> 16) & 0xff)
        bytes[2] = UInt8(truncatingIfNeeded: (i >> 8) & 0xff)
        bytes[3] = UInt8(truncatingIfNeeded: i & 0xff)
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
