import Foundation

nonisolated enum APIError: Error, Sendable, Equatable {
    /// No HTTP response (offline, timeout, TLS…): retried with the same identifiers.
    case transport(URLError.Code)
    case http(status: Int, code: String?, retryAfter: TimeInterval?, serverGeneration: String?, minimumVersion: String?, message: String?)
    /// Authentication impossible even after one refresh: the iPhone must be paired again.
    case unauthorized(code: String?)
    case invalidResponse
}

nonisolated struct DeviceDescription: Encodable, Sendable {
    let name: String
    let platform = "ios"
    let osVersion: String
    let appVersion: String
}

nonisolated struct TokenResponse: Decodable, Sendable {
    let userId: String
    let deviceId: String
    let accessToken: String
    let accessTokenExpiresAt: String
    let refreshToken: String
    let serverGeneration: String
}

nonisolated struct SyncTokenResponse: Decodable, Sendable {
    let token: String
    let expiresAt: String
    let endpoint: String?
    let userId: String
    let serverGeneration: String
}

nonisolated struct MutationOutcome: Decodable, Sendable {
    let outcome: String
    let code: String?
    let message: String?
}

nonisolated struct MutationResult: Decodable, Sendable {
    let clientCommandId: String
    let outcome: String
    let code: String?
    let message: String?
    let original: MutationOutcome?

    /// A rejection, including the stored result of a replayed command.
    var rejection: MutationOutcome? {
        if outcome == "rejected" { return MutationOutcome(outcome: outcome, code: code, message: message) }
        if outcome == "duplicate", let original, original.outcome == "rejected" { return original }
        return nil
    }
}

nonisolated struct MutationsResponse: Decodable, Sendable {
    let serverGeneration: String
    let results: [MutationResult]
}

private nonisolated struct PairBody: Encodable {
    let pairingSecret: String
    let device: DeviceDescription
}

private nonisolated struct RefreshBody: Encodable {
    let refreshToken: String
}

private nonisolated struct ErrorEnvelope: Decodable {
    nonisolated struct Body: Decodable {
        let code: String
        let message: String?
        let serverGeneration: String?
        let minimumVersion: String?
    }
    let error: Body
}

/// The backend's HTTP API (04_Backend/02_API_Contract.md §2, §3). One refresh at a time; tokens never logged.
actor APIClient {
    let baseURL: URL
    private let clientVersion: String
    private let credentials: CredentialStore
    private let urlSession: URLSession
    private var session: StoredSession?
    private var accessToken: (value: String, expiresAt: Date)?
    private var refreshing: Task<TokenResponse, any Error>?
    private var retired = false
    private let requireIdentityValidation: Bool
    private var onlineActionValidator: (@Sendable () async throws -> Void)?

    init(session: StoredSession, clientVersion: String, credentials: CredentialStore, urlSession: URLSession? = nil, requireIdentityValidation: Bool = false) {
        self.baseURL = session.apiBaseURL
        self.session = session
        self.clientVersion = clientVersion
        self.credentials = credentials
        self.urlSession = urlSession ?? Self.makeURLSession()
        self.requireIdentityValidation = requireIdentityValidation
    }

    /// `POST /auth/pair/complete` with the one-time secret shown by the homelab console.
    static func pair(baseURL: URL, secret: String, device: DeviceDescription, clientVersion: String) async throws -> TokenResponse {
        var request = URLRequest(url: baseURL.appending(path: "api/v1/auth/pair/complete"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(clientVersion, forHTTPHeaderField: "X-Client-Version")
        request.httpBody = try JSONEncoder().encode(PairBody(pairingSecret: secret, device: device))
        let (data, response) = try await send(request, with: makeURLSession())
        guard response.statusCode == 201 else { throw failure(data, response) }
        return try decode(TokenResponse.self, from: data)
    }

    /// Keeps the tokens of a fresh pairing, so that the first sync does not refresh at once.
    func adopt(_ tokens: TokenResponse) {
        guard !retired else { return }
        accessToken = (tokens.accessToken, Timestamp.parse(tokens.accessTokenExpiresAt) ?? Date())
    }

    /// Called before replacing pairing credentials. A late refresh can no longer overwrite them.
    func retire() {
        retired = true
        refreshing?.cancel()
        refreshing = nil
        accessToken = nil
        session = nil
        onlineActionValidator = nil
        urlSession.invalidateAndCancel()
    }

    /// An old device can establish its owner through its own valid refresh credentials.
    /// A newly paired device cannot use this to relabel an existing database.
    func establishedUserId() -> String? { session?.userId }

    func setOnlineActionValidator(_ validator: @escaping @Sendable () async throws -> Void) {
        guard !retired else { return }
        onlineActionValidator = validator
    }

    func syncToken() async throws -> SyncTokenResponse {
        let (data, response) = try await authorized("GET", "api/v1/auth/sync-token")
        guard response.statusCode == 200 else { throw Self.failure(data, response) }
        return try Self.decode(SyncTokenResponse.self, from: data)
    }

    func uploadMutations(_ body: Data) async throws -> MutationsResponse {
        let (data, response) = try await authorized("POST", "api/v1/sync/mutations", body: body)
        guard response.statusCode == 200 else { throw Self.failure(data, response) }
        return try Self.decode(MutationsResponse.self, from: data)
    }

    /// `POST /auth/logout`: revokes this device on the server.
    func logout() async throws {
        let (data, response) = try await authorized("POST", "api/v1/auth/logout")
        guard response.statusCode == 200 else { throw Self.failure(data, response) }
        accessToken = nil
    }

    /// JSON call with one expected status; any other status becomes an `APIError`.
    func call<Response: Decodable, Body: Encodable & Sendable>(_ method: String, _ path: String, body: Body,
                                                             expecting status: Int, timeout: TimeInterval = 30) async throws -> Response {
        let payload = try JSONEncoder().encode(body)
        let (data, response) = try await authorized(method, path, body: payload, timeout: timeout)
        guard response.statusCode == status else { throw Self.failure(data, response) }
        return try Self.decode(Response.self, from: data)
    }

    func call<Response: Decodable>(_ method: String, _ path: String, expecting status: Int, timeout: TimeInterval = 30) async throws -> Response {
        let (data, response) = try await authorized(method, path, timeout: timeout)
        guard response.statusCode == status else { throw Self.failure(data, response) }
        return try Self.decode(Response.self, from: data)
    }

    func callWithoutBody(_ method: String, _ path: String, expecting status: Int) async throws {
        let (data, response) = try await authorized(method, path)
        guard response.statusCode == status else { throw Self.failure(data, response) }
    }

    // MARK: - Tokens

    func authorized(_ method: String, _ path: String, body: Data? = nil, contentType: String = "application/json", timeout: TimeInterval = 30) async throws -> (Data, HTTPURLResponse) {
        for attempt in 0..<2 {
            guard !retired else { throw APIError.unauthorized(code: "SESSION_REPLACED") }
            try Task.checkCancellation()
            if requireIdentityValidation, method != "GET", path.hasPrefix("api/v1/assistant/") {
                guard let onlineActionValidator else { throw APIError.transport(.notConnectedToInternet) }
                try await onlineActionValidator()
            }
            let token = try await validAccessToken(forceRefresh: attempt > 0)
            // Token refresh is shared by callers; cancelling one caller must still prevent its upload.
            try Task.checkCancellation()
            guard !retired else { throw APIError.unauthorized(code: "SESSION_REPLACED") }
            var request = URLRequest(url: baseURL.appending(path: path))
            request.httpMethod = method
            request.timeoutInterval = timeout
            request.setValue(clientVersion, forHTTPHeaderField: "X-Client-Version")
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            if let body {
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
                request.httpBody = body
            }
            let (data, response) = try await Self.send(request, with: urlSession)
            guard !retired else { throw APIError.unauthorized(code: "SESSION_REPLACED") }
            // An access token revoked or expired early: one refresh, then give up.
            if response.statusCode == 401 && attempt == 0 { continue }
            return (data, response)
        }
        throw APIError.unauthorized(code: nil)
    }

    private func validAccessToken(forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let accessToken, accessToken.expiresAt.timeIntervalSinceNow > 60 {
            return accessToken.value
        }
        return try await refresh().accessToken
    }

    private func refresh() async throws -> TokenResponse {
        if let refreshing { return try await refreshing.value }
        guard let session else { throw APIError.unauthorized(code: "NOT_PAIRED") }
        let task = Task { try await self.performRefresh(session) }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func performRefresh(_ current: StoredSession) async throws -> TokenResponse {
        var request = URLRequest(url: baseURL.appending(path: "api/v1/auth/refresh"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(clientVersion, forHTTPHeaderField: "X-Client-Version")
        request.httpBody = try JSONEncoder().encode(RefreshBody(refreshToken: current.refreshToken))
        let (data, response) = try await Self.send(request, with: urlSession)
        try Task.checkCancellation()
        guard !retired, session == current else { throw APIError.unauthorized(code: "SESSION_REPLACED") }
        guard response.statusCode == 200 else {
            if response.statusCode == 401 { accessToken = nil }
            throw Self.failure(data, response)
        }
        let tokens = try Self.decode(TokenResponse.self, from: data)
        try Task.checkCancellation()
        guard !retired, session == current else { throw APIError.unauthorized(code: "SESSION_REPLACED") }
        guard tokens.deviceId.caseInsensitiveCompare(current.deviceId) == .orderedSame,
              current.userId.map({ $0.caseInsensitiveCompare(tokens.userId) == .orderedSame }) ?? true else {
            throw APIError.unauthorized(code: "IDENTITY_CHANGED")
        }
        // Stored before use: a lost write would still be covered by the server's one-minute replay window.
        var next = current
        next.refreshToken = tokens.refreshToken
        next.userId = tokens.userId
        try credentials.save(next)
        session = next
        adopt(tokens)
        return tokens
    }

    // MARK: - Transport

    private static func makeURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    private static func send(_ request: URLRequest, with urlSession: URLSession) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
            return (data, http)
        } catch let error as URLError {
            throw APIError.transport(error.code)
        }
    }

    static func failure(_ data: Data, _ response: HTTPURLResponse) -> APIError {
        let body = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
        if response.statusCode == 401 { return .unauthorized(code: body?.error.code) }
        return .http(
            status: response.statusCode,
            code: body?.error.code,
            retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) },
            serverGeneration: body?.error.serverGeneration,
            minimumVersion: body?.error.minimumVersion,
            message: body?.error.message
        )
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }
}
