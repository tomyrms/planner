import CryptoKit
import Foundation

/// Serial disk I/O, outside MainActor. Atomic journal/pointer writes make an interrupted switch replayable.
actor RecoveryFiles {
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? URL.applicationSupportDirectory.appending(path: "Recovery", directoryHint: .isDirectory)
    }

    func journal() throws -> RecoveryJournal? {
        let file = directory.appending(path: "current.json")
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return nil }
        do {
            let value = try JSONDecoder().decode(RecoveryJournal.self, from: Data(contentsOf: file))
            try value.validate()
            return value
        } catch { throw RecoveryError.invalidJournal }
    }

    func save(_ journal: RecoveryJournal) throws {
        try journal.validate()
        try prepareDirectory()
        try JSONEncoder().encode(journal).write(to: directory.appending(path: "current.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func activeReplica() throws -> RecoveryReplica {
        let file = directory.appending(path: "active-replica.json")
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return .legacy }
        let replica = try JSONDecoder().decode(RecoveryReplica.self, from: Data(contentsOf: file))
        guard replica.isValid else { throw RecoveryError.invalidJournal }
        return replica
    }

    func select(_ replica: RecoveryReplica) throws {
        guard replica.isValid else { throw RecoveryError.invalidJournal }
        try prepareDirectory()
        try JSONEncoder().encode(replica).write(to: directory.appending(path: "active-replica.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func archive(_ data: Data, journalId: UUID) throws -> RecoveryArchiveProof {
        try prepareDirectory()
        // An export must be valid JSON before an on-disk round-trip can prove its bytes.
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["localExportVersion"] as? Int == 1, json["pendingCommands"] is [Any], json["drafts"] != nil else {
            throw RecoveryError.archiveNotVerified
        }
        let proof = RecoveryArchiveProof(filename: "archive-\(journalId.uuidString.lowercased()).json", byteCount: data.count, sha256: Self.hash(data))
        try data.write(to: archiveURL(proof), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try verify(proof)
        return proof
    }

    func verify(_ proof: RecoveryArchiveProof) throws {
        let data: Data
        do { data = try Data(contentsOf: archiveURL(proof)) } catch { throw RecoveryError.archiveNotVerified }
        guard data.count == proof.byteCount, Self.hash(data) == proof.sha256 else { throw RecoveryError.archiveNotVerified }
    }

    func archiveData(_ proof: RecoveryArchiveProof) throws -> Data {
        try verify(proof)
        return try Data(contentsOf: archiveURL(proof))
    }

    func completedJournals() throws -> [RecoveryJournal] {
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("completed-") && $0.pathExtension == "json" }
            .map {
                let journal = try JSONDecoder().decode(RecoveryJournal.self, from: Data(contentsOf: $0))
                try journal.validate()
                guard journal.stage == .complete else { throw RecoveryError.invalidJournal }
                return journal
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func finish(_ journal: RecoveryJournal) throws {
        guard journal.stage == .complete else { throw RecoveryError.invalidJournal }
        try journal.validate()
        guard let archive = journal.archive else { throw RecoveryError.archiveNotVerified }
        try verify(archive)
        try JSONEncoder().encode(journal).write(
            to: directory.appending(path: "completed-\(journal.id.uuidString.lowercased()).json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        // The completed record and archive remain. Removing this barrier is the very last disk step.
        let current = directory.appending(path: "current.json")
        if FileManager.default.fileExists(atPath: current.path(percentEncoded: false)) { try FileManager.default.removeItem(at: current) }
    }

    func audioDirectory(for replica: RecoveryReplica) throws -> URL {
        guard replica.isValid else { throw RecoveryError.invalidJournal }
        let base = URL.applicationSupportDirectory
        var url = replica.audioScope.map { base.appending(path: "ReplicaAudio", directoryHint: .isDirectory).appending(path: $0, directoryHint: .isDirectory) }
            ?? base.appending(path: "PendingAudio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        return url
    }

    /// Retired replicas retain their audio only to the original 24-hour limit; audio is never archived.
    /// iOS cannot execute this while killed: overdue files are removed at the next launch.
    func pruneRetiredAudio(excluding active: RecoveryReplica, at now: Date = Date()) throws -> TimeInterval? {
        let base = URL.applicationSupportDirectory
        let scoped = base.appending(path: "ReplicaAudio", directoryHint: .isDirectory)
        var directories = (try? FileManager.default.contentsOfDirectory(at: scoped, includingPropertiesForKeys: nil)) ?? []
        directories = directories.filter { UUID(uuidString: $0.lastPathComponent) != nil && $0.lastPathComponent != active.audioScope }
        if active.audioScope != nil { directories.append(base.appending(path: "PendingAudio", directoryHint: .isDirectory)) }
        var next: TimeInterval?
        for folder in directories {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
            for file in files where file.pathExtension == "m4a" {
                let created = try file.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast
                let remaining = created.addingTimeInterval(24 * 3600).timeIntervalSince(now)
                if remaining <= 0 { try FileManager.default.removeItem(at: file) }
                else { next = min(next ?? remaining, remaining) }
            }
        }
        return next
    }

    private func archiveURL(_ proof: RecoveryArchiveProof) throws -> URL {
        guard proof.filename.hasPrefix("archive-"), proof.filename.hasSuffix(".json"),
              proof.filename == URL(fileURLWithPath: proof.filename).lastPathComponent,
              !proof.filename.contains("\\") else { throw RecoveryError.archiveNotVerified }
        return directory.appending(path: proof.filename)
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
