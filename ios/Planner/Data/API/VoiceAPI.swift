import Foundation

/// Transcription snapshot (04_Backend/02_API_Contract.md §4.7).
nonisolated struct TranscriptionSnapshot: Decodable, Sendable, Equatable {
    let transcriptionId: String
    let status: String
    let text: String?
    let errorCode: String?
}

extension APIClient {
    /// `POST /assistant/transcriptions`: multipart with the identifier, the duration and the audio file.
    func uploadVoice(transcriptionId: String, durationMs: Int, file: URL) async throws -> TranscriptionSnapshot {
        let boundary = "planner-" + UUID().uuidString
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("transcriptionId", transcriptionId)
        field("durationMs", String(durationMs))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"message.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        body.append(try Data(contentsOf: file))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let (data, response) = try await authorized(
            "POST", "api/v1/assistant/transcriptions", body: body,
            contentType: "multipart/form-data; boundary=\(boundary)", timeout: 90
        )
        guard response.statusCode == 200 else { throw Self.failure(data, response) }
        return try Self.decode(TranscriptionSnapshot.self, from: data)
    }

    func transcription(_ id: String) async throws -> TranscriptionSnapshot {
        try await call("GET", "api/v1/assistant/transcriptions/\(id)", expecting: 200)
    }

    /// Abandon: the server deletes its copy of the audio at once.
    func abandonTranscription(_ id: String) async throws {
        let _: TranscriptionSnapshot = try await call("DELETE", "api/v1/assistant/transcriptions/\(id)", expecting: 200)
    }
}
