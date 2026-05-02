// MacrecCore/Transcription/Providers/AppleSpeechTranscriptionProvider.swift —
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
// Reconciliation invariants (see Phase D self-review checklist):
//
//   * `nextUtteranceCounter` is the source of truth for utterance ids; it
//     increments every time a new id is minted (whether the seed result is
//     a partial or a final). The plan-005 sketch's `currentUtteranceId(for:)`
//     was non-incrementing — Constraint #6 in the Phase D brief replaces
//     it with the incrementing variant implemented here.
//   * `currentIdForLocale` is the per-locale "open utterance" slot. A
//     final clears the slot for that locale; the next non-final from the
//     same locale opens a fresh utterance with a new id.
//   * `pendingFinals` buffers per-utterance finals from each locale. As
//     soon as every analyzer has reported a final for the same id, OR
//     `reconciliationWindowMs` elapses since the first final landed,
//     `reconcile(_:)` picks the winner and emits one `.final` event.
//   * `reconciledUtteranceIds` ensures the timeout-driven reconcile path
//     is a no-op when the all-locales-arrived path already fired.
//
// The session uses an `NSLock` to guard the four pieces of mutable state
// (`nextUtteranceCounter`, `currentIdForLocale`, `pendingFinals`,
// `reconciledUtteranceIds`) so the multiple per-locale drain `Task`s and
// the timeout `Task`s do not race.

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
        logger: Logger = Logger(label: "macrec.transcription.apple"),
        analyzerFactory: (@Sendable (Locale) throws -> any SpeechAnalyzerAdapter)? = nil
    ) {
        self.logger = logger
        if let analyzerFactory {
            self.analyzerFactory = analyzerFactory
        } else {
            // Default factory captures the provider's logger so the
            // adapter's internal Tasks can log asset-install / analyzer-
            // start failures into the same log file the rest of macrec-ui
            // writes to (`~/.tool-agents/macrec-ui/macrec-ui.log`).
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
        // `MACREC_TRANSCRIBE_LANGUAGE` to a supported value).
        let supportedSet = Set(SFSpeechRecognizer.supportedLocales().map { $0.identifier })
        for (raw, canonical) in zip(rawLocales, canonicalLocales) {
            guard supportedSet.contains(canonical.identifier) else {
                let preview = supportedSet.sorted().prefix(20).joined(separator: ", ")
                let hintNote = (raw.identifier == canonical.identifier)
                    ? "locale '\(raw.identifier)'"
                    : "locale '\(raw.identifier)' (canonicalised to '\(canonical.identifier)')"
                throw MacrecError.transcriptionConfigConflict(
                    reason: "Apple Speech: \(hintNote) is not in the on-device supported set on this Mac. Set MACREC_TRANSCRIBE_LANGUAGE to a supported value (e.g. 'en-US' or 'el-GR') in ~/.tool-agents/macrec-ui/.env. First few supported: \(preview)…"
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
    public static let reconciliationWindowMs: Int = 150

    private let analyzers: [(locale: Locale, adapter: any SpeechAnalyzerAdapter)]
    private let source: SourceTag
    private let logger: Logger
    private let eventsContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation
    public let events: AsyncStream<StreamingTranscriptionEvent>

    private let lock = NSLock()
    private var nextUtteranceCounter: Int = 0
    /// Per-locale "current open utterance" id. When a final arrives for a
    /// locale, that locale's slot is cleared; the next non-final result for
    /// the locale assigns a fresh id.
    private var currentIdForLocale: [String: Int] = [:]
    private var pendingFinals: [Int: [(locale: Locale, result: TranscriptionResult)]] = [:]
    private var reconciledUtteranceIds: Set<Int> = []

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
            Task { [weak self] in
                for await result in adapter.results {
                    self?.handle(result, from: locale)
                }
            }
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
        let utteranceId = openOrAssignUtteranceId(for: locale, isFinal: result.isFinal)

        if !result.isFinal {
            eventsContinuation.yield(
                .partial(
                    utteranceId: Self.utteranceIdToUUID(utteranceId),
                    text: result.text,
                    confidence: result.confidence,
                    speaker: nil
                )
            )
            return
        }

        // Final — buffer for reconciliation, close the per-locale open id.
        lock.lock()
        var arr = pendingFinals[utteranceId] ?? []
        arr.append((locale, result))
        pendingFinals[utteranceId] = arr
        currentIdForLocale.removeValue(forKey: locale.identifier)
        let collected = arr.count
        lock.unlock()

        if collected == analyzers.count {
            reconcile(utteranceId)
        } else {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Self.reconciliationWindowMs))
                self?.reconcile(utteranceId)
            }
        }
    }

    private func openOrAssignUtteranceId(for locale: Locale, isFinal: Bool) -> Int {
        lock.lock(); defer { lock.unlock() }
        if let existing = currentIdForLocale[locale.identifier] {
            return existing
        }
        let id = nextUtteranceCounter
        nextUtteranceCounter += 1
        if !isFinal {
            // Open a new utterance for this locale; finals close it.
            currentIdForLocale[locale.identifier] = id
        }
        return id
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
