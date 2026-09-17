import Foundation
import PowerSync
import Testing
@testable import Planner

/// Real API/connector/SQLite boundaries, with every HTTP request intercepted and isolated Keychain items.
@MainActor
struct SyncRecoveryBoundaryTests {
    @Test func changedGenerationBlocksBeforeCredentialsAndKeepsTheQueue() async throws {
        try await withFixture { fixture in
            let changed = UUID().uuidString.lowercased()
            try fixture.replySync(generation: changed)
            let before = try await fixture.queueRows()
            try await expectBlocked(fixture.connector(), by: .generationChanged(changed))
            let saved = try await LocalMeta.recoveryBlock(in: fixture.db)
            let after = try await fixture.queueRows()
            #expect(saved == .generationChanged(changed))
            #expect(after == before)
            #expect(fixture.http.paths == ["/api/v1/auth/sync-token"])
        }
    }

    @Test func anotherOwnerBlocksBeforeCredentialsAndCannotRelabelTheReplica() async throws {
        try await withFixture { fixture in
            try fixture.replySync(userId: UUID().uuidString.lowercased())
            let before = try await fixture.queueRows()
            try await expectBlocked(fixture.connector(), by: .pairingRequired)
            let saved = try await LocalMeta.recoveryBlock(in: fixture.db)
            let owner = try await LocalMeta.ownerUserId(in: fixture.db)
            let after = try await fixture.queueRows()
            #expect(saved == .pairingRequired)
            #expect(owner == fixture.userId)
            #expect(after == before)
        }
    }

    @Test(arguments: [SyncBlock.pairingRequired, .generationChanged("restored-generation")])
    func aRecreatedConnectorAndRetryCannotBypassThePersistedBlock(_ block: SyncBlock) async throws {
        try await withFixture { fixture in
            let original = fixture.connector()
            try await original.requireRecovery(block)
            let saved = try await LocalMeta.recoveryBlock(in: fixture.db)
            #expect(saved == block)

            // This connector has no in-memory block: only the durable SQLite value can stop it.
            let relaunched = fixture.connector()
            try await expectBlocked(relaunched, by: block)
            await relaunched.clearBlock()
            try await expectBlocked(relaunched, by: block)
            do {
                try await relaunched.uploadData(database: fixture.db)
                Issue.record("A recovery block must stop uploads before reading or acknowledging the queue.")
            } catch let error as SyncBlockedError {
                #expect(error.block == block)
            }
            #expect(fixture.http.paths.isEmpty)
            let pending = try await Outbox.pendingSummary(in: fixture.db)
            #expect(pending.count == 1)
        }
    }

    @Test func legacyOwnerIsEstablishedByTheExistingDevicesValidRefresh() async throws {
        try await withFixture(legacy: true, adoptAccess: false) { fixture in
            try fixture.replyRefresh()
            try fixture.replySync()
            let result = try await fixture.connector().fetchCredentials()
            #expect(result != nil)
            let owner = try await LocalMeta.ownerUserId(in: fixture.db)
            let stored = try fixture.credentials.load()
            let savedBlock = try await LocalMeta.recoveryBlock(in: fixture.db)
            #expect(owner == fixture.userId)
            #expect(stored?.userId == fixture.userId)
            #expect(stored?.deviceId == fixture.deviceId)
            #expect(savedBlock == nil)
            #expect(fixture.http.paths == ["/api/v1/auth/refresh", "/api/v1/auth/sync-token"])
        }
    }

    @Test func adoptingAnAccessTokenAloneCannotAssignAnUnknownLegacyOwner() async throws {
        try await withFixture(legacy: true) { fixture in
            try fixture.replySync()
            try await expectBlocked(fixture.connector(), by: .pairingRequired)
            let owner = try await LocalMeta.ownerUserId(in: fixture.db)
            let stored = try fixture.credentials.load()
            #expect(owner == nil)
            #expect(stored?.userId == nil)
            #expect(fixture.http.paths == ["/api/v1/auth/sync-token"])
        }
    }

    @Test func legacyRefreshForAnotherDeviceCannotAssignAnOwnerOrReplaceCredentials() async throws {
        try await withFixture(legacy: true, adoptAccess: false) { fixture in
            try fixture.replyRefresh(deviceId: UUID().uuidString.lowercased())
            let result = try await fixture.connector().fetchCredentials()
            #expect(result == nil)
            let owner = try await LocalMeta.ownerUserId(in: fixture.db)
            let stored = try fixture.credentials.load()
            let block = try await LocalMeta.recoveryBlock(in: fixture.db)
            #expect(owner == nil)
            #expect(stored == fixture.original)
            #expect(block == .pairingRequired)
            #expect(fixture.http.paths == ["/api/v1/auth/refresh"])
        }
    }

    @Test func refreshCannotSwitchAKnownSessionToAnotherOwner() async throws {
        try await withFixture(adoptAccess: false) { fixture in
            try fixture.replyRefresh(userId: UUID().uuidString.lowercased())
            let result = try await fixture.connector().fetchCredentials()
            #expect(result == nil)
            let stored = try fixture.credentials.load()
            let owner = try await LocalMeta.ownerUserId(in: fixture.db)
            #expect(stored == fixture.original)
            #expect(owner == fixture.userId)
            #expect(fixture.http.paths == ["/api/v1/auth/refresh"])
        }
    }

    @Test(.timeLimit(.minutes(1))) func retiringDuringARefreshPreservesTheReplacementKeychainSession() async throws {
        try await withFixture(adoptAccess: false) { fixture in
            try fixture.replyRefresh(held: true)
            let inFlight = Task { try await fixture.api.syncToken() }
            defer { inFlight.cancel() }
            var requests = fixture.http.started.makeAsyncIterator()
            let first = await requests.next()
            #expect(first == "/api/v1/auth/refresh")

            await fixture.api.retire()
            let replacement = StoredSession(
                apiBaseURL: URL(string: "https://replacement.invalid")!, deviceId: UUID().uuidString,
                refreshToken: "replacement-test-token", userId: UUID().uuidString
            )
            try fixture.credentials.save(replacement)
            fixture.http.releaseHeldResponses()
            do {
                _ = try await inFlight.value
                Issue.record("The retired API must not finish a request with old credentials.")
            } catch is CancellationError {
                // The shared refresh task was cancelled before its response could be stored.
            } catch let error as APIError {
                #expect(error == .transport(.cancelled) || error == .unauthorized(code: "SESSION_REPLACED"))
            }
            let saved = try fixture.credentials.load()
            #expect(saved == replacement)

            // adopt() cannot resurrect a retired actor, even with a still-valid access token.
            await fixture.api.adopt(fixture.tokens())
            do {
                _ = try await fixture.api.syncToken()
                Issue.record("A retired API must reject subsequent requests without using the network.")
            } catch let error as APIError {
                #expect(error == .unauthorized(code: "SESSION_REPLACED"))
            }
            #expect(fixture.http.paths == ["/api/v1/auth/refresh"])
        }
    }

    private func expectBlocked(_ connector: SyncConnector, by expected: SyncBlock) async throws {
        do {
            _ = try await connector.fetchCredentials()
            Issue.record("Credentials must not be handed to PowerSync before recovery.")
        } catch let error as SyncBlockedError {
            #expect(error.block == expected)
        }
    }

    private func withFixture(legacy: Bool = false, adoptAccess: Bool = true,
                             _ work: @MainActor (RecoveryBoundaryFixture) async throws -> Void) async throws {
        let fixture = RecoveryBoundaryFixture(legacy: legacy)
        do {
            try await fixture.prepare(adoptAccess: adoptAccess)
            try await work(fixture)
            try await fixture.close()
        } catch {
            try? await fixture.close()
            throw error
        }
    }
}

@MainActor
private final class RecoveryBoundaryFixture {
    let userId = UUID().uuidString.lowercased()
    let deviceId = UUID().uuidString.lowercased()
    let generation = UUID().uuidString.lowercased()
    let db = LocalDatabase.open(fileName: "sync-boundary-" + UUID().uuidString + ".sqlite")
    let credentials = CredentialStore(account: "sync-boundary-" + UUID().uuidString)
    let http = RecoveryHTTPScenario()
    let original: StoredSession
    let api: APIClient

    init(legacy: Bool) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecoveryURLProtocol.self]
        configuration.timeoutIntervalForRequest = 5
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        original = StoredSession(apiBaseURL: http.baseURL, deviceId: deviceId,
                                 refreshToken: "original-test-token", userId: legacy ? nil : userId)
        api = APIClient(session: original, clientVersion: "0.1.0", credentials: credentials,
                        urlSession: URLSession(configuration: configuration))
        RecoveryURLProtocol.registry.install(http)
    }

    func prepare(adoptAccess: Bool) async throws {
        try credentials.save(original)
        try await LocalMeta.setServerGeneration(generation, in: db)
        if let owner = original.userId { try await LocalMeta.setOwnerUserId(owner, in: db) }
        let command = LocalCommand(type: "task.create", aggregateId: UUID().uuidString, chaining: .never,
                                   payload: ["title": "Offline task"])
        try await db.writeTransaction { tx in
            try tx.execute(sql: "INSERT INTO tasks (id, title) VALUES (?, 'Offline task')", parameters: [command.aggregateId])
            try Outbox.insert(command, in: tx)
        }
        if adoptAccess { await api.adopt(tokens()) }
    }

    func connector() -> SyncConnector {
        let events = AsyncStream<SyncBlock?>.makeStream()
        return SyncConnector(api: api, database: db, events: events.continuation)
    }

    func tokens() -> TokenResponse {
        TokenResponse(userId: userId, deviceId: deviceId, accessToken: "test-access-token",
                      accessTokenExpiresAt: Timestamp.format(Date().addingTimeInterval(3_600)),
                      refreshToken: "rotated-test-token", serverGeneration: generation)
    }

    func replyRefresh(userId: String? = nil, deviceId: String? = nil, held: Bool = false) throws {
        let values = tokens()
        try http.reply(to: "/api/v1/auth/refresh", held: held, body: [
            "userId": userId ?? values.userId, "deviceId": deviceId ?? values.deviceId,
            "accessToken": values.accessToken, "accessTokenExpiresAt": values.accessTokenExpiresAt,
            "refreshToken": values.refreshToken, "serverGeneration": values.serverGeneration,
        ])
    }

    func replySync(userId: String? = nil, generation: String? = nil) throws {
        try http.reply(to: "/api/v1/auth/sync-token", body: [
            "token": "test-sync-token", "expiresAt": Timestamp.format(Date().addingTimeInterval(900)),
            "endpoint": "https://sync.invalid", "userId": userId ?? self.userId,
            "serverGeneration": generation ?? self.generation,
        ])
    }

    func queueRows() async throws -> [String] {
        try await db.getAll(sql: "SELECT data FROM ps_crud ORDER BY id", parameters: []) {
            try $0.getString(index: 0)
        }
    }

    func close() async throws {
        await api.retire()
        http.releaseHeldResponses()
        http.finish()
        RecoveryURLProtocol.registry.remove(http)
        try credentials.delete()
        try await db.disconnectAndClear()
    }
}

/// This protocol intercepts every request: a missing stub fails locally instead of falling through to HTTP.
private final class RecoveryURLProtocol: URLProtocol, @unchecked Sendable {
    static let registry = RecoveryHTTPRegistry()
    private let state = NSLock()
    private var finished = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let scenario = Self.registry.scenario(for: request.url?.host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        scenario.receive(self)
    }

    override func stopLoading() { state.withLock { finished = true } }

    func deliver(_ reply: RecoveryHTTPScenario.Reply) {
        let shouldDeliver = state.withLock {
            guard !finished else { return false }
            finished = true
            return true
        }
        guard shouldDeliver, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class RecoveryHTTPRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var scenarios: [String: RecoveryHTTPScenario] = [:]

    func install(_ scenario: RecoveryHTTPScenario) {
        lock.withLock { scenarios[scenario.host] = scenario }
    }

    func remove(_ scenario: RecoveryHTTPScenario) {
        _ = lock.withLock { scenarios.removeValue(forKey: scenario.host) }
    }

    func scenario(for host: String?) -> RecoveryHTTPScenario? {
        lock.withLock { host.flatMap { scenarios[$0] } }
    }
}

private final class RecoveryHTTPScenario: @unchecked Sendable {
    struct Reply: Sendable {
        let body: Data
        let status: Int
        let held: Bool
    }

    let host = "recovery-" + UUID().uuidString.lowercased() + ".invalid"
    var baseURL: URL { URL(string: "https://" + host)! }
    let started: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var replies: [String: Reply] = [:]
    private var received: [String] = []
    private var held: [(RecoveryURLProtocol, Reply)] = []
    var paths: [String] { lock.withLock { received } }

    init() {
        let stream = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(20))
        started = stream.stream
        continuation = stream.continuation
    }

    func reply(to path: String, held: Bool = false, body: [String: String]) throws {
        let reply = Reply(body: try JSONEncoder().encode(body), status: 200, held: held)
        lock.withLock { replies[path] = reply }
    }

    func receive(_ request: RecoveryURLProtocol) {
        let path = request.request.url?.path ?? ""
        let response: Reply? = lock.withLock {
            received.append(path)
            let reply = replies[path] ?? Reply(body: Data(), status: 500, held: false)
            if reply.held {
                held.append((request, reply))
                return nil
            }
            return reply
        }
        continuation.yield(path)
        if let response { request.deliver(response) }
    }

    func releaseHeldResponses() {
        let responses = lock.withLock {
            defer { held.removeAll() }
            return held
        }
        for (request, reply) in responses { request.deliver(reply) }
    }

    func finish() { continuation.finish() }
}
