import Foundation
import Observation

@Observable
final class SyncRecoveryState {
    var journal: RecoveryJournal?
    var isBusy = false
    var message: String?
    var archiveData: Data?

    var decision: RecoveryDecision? {
        guard let journal, let candidate = journal.candidateIdentity else { return nil }
        return try? journal.sourceIdentity.decision(for: candidate)
    }
}
