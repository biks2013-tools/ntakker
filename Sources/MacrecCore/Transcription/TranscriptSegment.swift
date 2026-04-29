// Sources/MacrecCore/Transcription/TranscriptSegment.swift
import Foundation

public struct TranscriptSegment: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public var lastUpdated: Date
    public var text: String
    public let source: SourceTag
    public let confidence: Float?
    public let model: String?
    public let durationSec: Double?
    public let language: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        lastUpdated: Date? = nil,
        text: String,
        source: SourceTag,
        confidence: Float? = nil,
        model: String? = nil,
        durationSec: Double? = nil,
        language: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.lastUpdated = lastUpdated ?? timestamp
        self.text = text
        self.source = source
        self.confidence = confidence
        self.model = model
        self.durationSec = durationSec
        self.language = language
    }
}
