// Sources/MacrecCore/Transcription/Providers/GeminiRESTSchema.swift
import Foundation

enum GeminiREST {

    struct Request: Encodable {
        let contents: [Content]
        let generationConfig: GenerationConfig

        struct Content: Encodable {
            let parts: [Part]
        }

        enum Part: Encodable {
            case text(String)
            case inlineAudio(mimeType: String, base64Data: String)

            enum CodingKeys: String, CodingKey {
                case text
                case inlineData
            }
            enum InlineKeys: String, CodingKey {
                case mimeType
                case data
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .text(let s):
                    try c.encode(s, forKey: .text)
                case .inlineAudio(let mime, let data):
                    var nested = c.nestedContainer(keyedBy: InlineKeys.self, forKey: .inlineData)
                    try nested.encode(mime, forKey: .mimeType)
                    try nested.encode(data, forKey: .data)
                }
            }
        }

        struct GenerationConfig: Encodable {
            let temperature: Double
            let candidateCount: Int
        }
    }

    struct Response: Decodable {
        let candidates: [Candidate]?
        let error: ErrorDetail?

        struct Candidate: Decodable {
            let content: Content?
        }
        struct Content: Decodable {
            let parts: [Part]?
        }
        struct Part: Decodable {
            let text: String?
        }
        struct ErrorDetail: Decodable {
            let code: Int?
            let message: String?
            let status: String?
        }
    }
}
