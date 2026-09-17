import Foundation
import PowerSync
import Testing
import UserNotifications
@testable import Planner

@MainActor
struct ReminderReconcilerTests {
    @Test(.timeLimit(.minutes(1))) func stoppingDuringDebouncePreventsEverySchedulingEffect() async throws {
        try await withHarness(debounce: .seconds(3_600)) { db, center, reconciler in
            await reconciler.start()
            await reconciler.stopAndWait()
            reconciler.requestPass()
            await reconciler.waitForPendingPass()
            let proofs = try await ReminderReconciler.loadAcceptances(db)
            #expect(center.authorizationReads == 0)
            #expect(center.added.isEmpty)
            #expect(proofs.isEmpty)
            #expect(reconciler.states.isEmpty)
        }
    }

    @Test(.timeLimit(.minutes(1))) func stoppingDuringSystemReadWaitsAndNeverAppliesTheOldSnapshot() async throws {
        try await withHarness { db, center, reconciler in
            let read = ReminderGate()
            center.nextRead = read
            await reconciler.start()
            try await read.waitUntilEntered()
            let started = ReminderSignal()
            var stopped = false
            let stopping = Task {
                started.signal()
                await reconciler.stopAndWait()
                stopped = true
            }
            await started.wait()
            #expect(!stopped)
            read.release()
            await stopping.value
            let proofs = try await ReminderReconciler.loadAcceptances(db)
            #expect(stopped)
            #expect(center.added.isEmpty)
            #expect(proofs.isEmpty)
            #expect(reconciler.states.isEmpty)
        }
    }

    @Test(.timeLimit(.minutes(1))) func stopAwaitsNonCancellableAddAndItsCleanupBeforeReturning() async throws {
        try await withHarness { db, center, reconciler in
            let add = ReminderGate()
            let removal = ReminderGate()
            center.nextAdd = add
            center.nextRemoval = removal
            await reconciler.start()
            try await add.waitUntilEntered()
            let started = ReminderSignal()
            var stopped = false
            let stopping = Task {
                started.signal()
                await reconciler.stopAndWait()
                stopped = true
            }
            await started.wait()
            #expect(!stopped)
            add.release()
            try await removal.waitUntilEntered()
            #expect(!stopped)
            #expect(center.pending.count == 1) // The fake system accepted the cancelled call.
            removal.release()
            await stopping.value
            let proofs = try await ReminderReconciler.loadAcceptances(db)
            #expect(stopped)
            #expect(center.pending.isEmpty)
            #expect(proofs.isEmpty)
            #expect(reconciler.states.isEmpty)
            #expect(center.events == ["add.begin", "add.end", "remove.begin", "remove.end"])
        }
    }

    @Test(.timeLimit(.minutes(1))) func changedReminderWaitsForObsoleteAddCleanupThenRecordsOnlyTheNewTime() async throws {
        try await withHarness { db, center, reconciler in
            let add = ReminderGate()
            let removal = ReminderGate()
            center.nextAdd = add
            center.nextRemoval = removal
            await reconciler.start()
            try await add.waitUntilEntered()
            let old = try #require(center.added.first)
            let replacement = old.triggerAt.addingTimeInterval(3_600)
            let wall = TimeResolver.project(replacement, into: TimeZone(identifier: "UTC")!)
            try await db.execute(
                sql: "UPDATE reminders SET absolute_date = ?, absolute_time = ?, updated_at = ? WHERE id = ?",
                parameters: [wall.date.description, wall.time.description, Timestamp.format(Date()), Self.reminderId]
            )
            reconciler.requestPass()
            add.release()
            try await removal.waitUntilEntered()
            #expect(center.added.count == 1) // A newer pass cannot race the stale cleanup.
            removal.release()
            await reconciler.waitForPendingPass()
            let proofs = try await ReminderReconciler.loadAcceptances(db)
            #expect(center.pending[old.notificationId]?.triggerAt == replacement)
            #expect(proofs[old.notificationId]?.triggerAt == replacement)
            #expect(reconciler.states[old.notificationId] == .scheduled)
            #expect(center.maxConcurrentAdds == 1)
            #expect(Array(center.events.prefix(5)) == ["add.begin", "add.end", "remove.begin", "remove.end", "add.begin"])
        }
    }

    @Test(.timeLimit(.minutes(1))) func restartWaitsForOldCleanupAndKeepsItsOwnNotification() async throws {
        try await withHarness { db, center, reconciler in
            let add = ReminderGate()
            let removal = ReminderGate()
            center.nextAdd = add
            center.nextRemoval = removal
            await reconciler.start()
            try await add.waitUntilEntered()
            let stoppingStarted = ReminderSignal()
            let stopping = Task {
                stoppingStarted.signal()
                await reconciler.stopAndWait()
            }
            await stoppingStarted.wait()
            let restartingStarted = ReminderSignal()
            var restarted = false
            let restarting = Task {
                restartingStarted.signal()
                await reconciler.start()
                restarted = true
            }
            await restartingStarted.wait()
            #expect(!restarted)
            add.release()
            try await removal.waitUntilEntered()
            #expect(!restarted)
            #expect(center.registrations == 1)
            removal.release()
            await stopping.value
            await restarting.value
            await reconciler.waitForPendingPass()
            let proofs = try await ReminderReconciler.loadAcceptances(db)
            #expect(restarted)
            #expect(center.registrations == 2)
            #expect(center.pending.count == 1)
            #expect(proofs.count == 1)
            #expect(center.maxConcurrentAdds == 1)
            // Ordinary stop retains a notification which finished programming before the stop.
            let pending = center.pending
            await reconciler.stopAndWait()
            #expect(center.pending == pending)
            let pendingId = try #require(pending.keys.first)
            #expect(reconciler.states[pendingId] == .scheduled)
        }
    }

    private static let reminderId = "00000000-0000-4000-8000-000000000002"

    private func withHarness(
        debounce: Duration = .milliseconds(5),
        _ work: @MainActor (any PowerSyncDatabaseProtocol, ReminderSystemDouble, ReminderReconciler) async throws -> Void
    ) async throws {
        let db = LocalDatabase.open(fileName: "reminder-reconciler-" + UUID().uuidString + ".sqlite")
        let center = ReminderSystemDouble()
        let reconciler = ReminderReconciler(db: db, notifications: center.client, debounce: debounce)
        do {
            let wall = TimeResolver.project(Date().addingTimeInterval(3_600), into: TimeZone(identifier: "UTC")!)
            try await db.execute(
                sql: "INSERT INTO tasks (id, title, status, priority, revision) VALUES (?, 'Rappel synthétique', 'active', 'none', 1)",
                parameters: ["00000000-0000-4000-8000-000000000001"]
            )
            try await db.execute(
                sql: "INSERT INTO reminders (id, task_id, kind, absolute_date, absolute_time, absolute_time_zone, state) VALUES (?, ?, 'absolute', ?, ?, 'UTC', 'active')",
                parameters: [Self.reminderId, "00000000-0000-4000-8000-000000000001", wall.date.description, wall.time.description]
            )
            try await work(db, center, reconciler)
            center.releaseAll()
            await reconciler.stopAndWait()
            try await db.disconnectAndClear()
        } catch {
            center.releaseAll()
            await reconciler.stopAndWait()
            try? await db.disconnectAndClear()
            throw error
        }
    }
}

/// Every external suspension is under the test's control. Like the system add API, block() ignores
/// cancellation until explicitly released, so cancelling the worker alone cannot make these tests pass.
@MainActor
private final class ReminderGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var blocked: [CheckedContinuation<Void, Never>] = []

    func block() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { blocked.append($0) }
    }

    func waitUntilEntered() async throws {
        await withTaskCancellationHandler {
            if !entered && !released {
                await withCheckedContinuation { entryWaiters.append($0) }
            }
        } onCancel: {
            Task { @MainActor in self.release() }
        }
        try Task.checkCancellation()
    }

    func release() {
        released = true
        let waiters = entryWaiters + blocked
        entryWaiters.removeAll()
        blocked.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

@MainActor
private final class ReminderSignal {
    private var signalled = false
    private var waiter: CheckedContinuation<Void, Never>?
    func signal() { signalled = true; waiter?.resume(); waiter = nil }
    func wait() async {
        guard !signalled else { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

@MainActor
private final class ReminderSystemDouble {
    var pending: [String: ReminderMath.Request] = [:]
    var added: [ReminderMath.Request] = []
    var events: [String] = []
    var registrations = 0
    var authorizationReads = 0
    var maxConcurrentAdds = 0
    var nextRead: ReminderGate?
    var nextAdd: ReminderGate?
    var nextRemoval: ReminderGate?
    private var inFlightAdds = 0
    private var activeGates: [ReminderGate] = []

    var client: ReminderReconciler.NotificationClient {
        .init(
            registerCategory: { self.registrations += 1 },
            authorizationStatus: { self.authorizationReads += 1; return .authorized },
            requestAuthorization: {},
            pendingRequests: {
                let snapshot = Array(self.pending.values)
                if let gate = self.nextRead {
                    self.nextRead = nil
                    self.activeGates.append(gate)
                    await gate.block()
                }
                return snapshot
            },
            add: { request, _ in
                self.added.append(request)
                self.events.append("add.begin")
                self.inFlightAdds += 1
                self.maxConcurrentAdds = max(self.maxConcurrentAdds, self.inFlightAdds)
                if let gate = self.nextAdd {
                    self.nextAdd = nil
                    self.activeGates.append(gate)
                    await gate.block()
                }
                self.pending[request.notificationId] = request
                self.inFlightAdds -= 1
                self.events.append("add.end")
                return true
            },
            removePending: { ids in
                guard !ids.isEmpty else { return }
                self.events.append("remove.begin")
                if let gate = self.nextRemoval {
                    self.nextRemoval = nil
                    self.activeGates.append(gate)
                    await gate.block()
                }
                for id in ids { self.pending[id] = nil }
                self.events.append("remove.end")
            }
        )
    }

    func releaseAll() {
        for gate in activeGates { gate.release() }
        nextRead?.release()
        nextAdd?.release()
        nextRemoval?.release()
    }
}
