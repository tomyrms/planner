import Foundation
import Observation

/// The view owns and cancels the loading task. A late response cannot replace a newer refresh.
@Observable
final class DiagnosticsStore {
    enum Failure: Equatable {
        case offline, unreachable, authorization, unavailable, invalidResponse

        var message: String {
            switch self {
            case .offline: "Hors ligne. Les diagnostics du serveur seront disponibles avec une connexion."
            case .unreachable: "Le serveur est injoignable. Vérifiez la connexion au serveur, puis réessayez."
            case .authorization: "Cet iPhone n’est plus autorisé à lire les diagnostics. Ouvrez la récupération dans Réglages."
            case .unavailable: "Les diagnostics sont temporairement indisponibles. Réessayez dans un instant."
            case .invalidResponse: "La réponse du serveur est illisible. Réessayez ou mettez l’app à jour."
            }
        }
    }

    private(set) var snapshot: DiagnosticsSnapshot?
    private(set) var failure: Failure?
    private(set) var isLoading = false
    @ObservationIgnored private var requestId: UUID?

    func refresh(using api: any DiagnosticsAPI) async {
        let id = UUID()
        requestId = id
        isLoading = true
        failure = nil
        defer { if requestId == id { isLoading = false } }
        do {
            let response = try await api.diagnostics()
            try Task.checkCancellation()
            guard requestId == id else { return }
            guard Timestamp.parse(response.generatedAt) != nil else { throw APIError.invalidResponse }
            snapshot = response
        } catch {
            guard requestId == id, !Task.isCancelled else { return }
            if error is CancellationError { return }
            failure = Self.failure(for: error)
        }
    }

    func cancel() {
        requestId = nil
        isLoading = false
    }

    private static func failure(for error: any Error) -> Failure {
        switch error {
        case APIError.transport(.notConnectedToInternet), APIError.transport(.dataNotAllowed): .offline
        case APIError.transport: .unreachable
        case APIError.unauthorized, APIError.http(status: 401, code: _, retryAfter: _, serverGeneration: _, minimumVersion: _, message: _): .authorization
        case APIError.invalidResponse: .invalidResponse
        case is DecodingError: .invalidResponse
        default: .unavailable
        }
    }
}
