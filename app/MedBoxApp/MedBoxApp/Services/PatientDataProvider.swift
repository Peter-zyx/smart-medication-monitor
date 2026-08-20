import Foundation

struct PatientSnapshot: Equatable, Sendable {
    let patientID: String
    let prescriptions: [Prescription]
    let history: [MedicationEventRecord]
}

enum PatientLookupError: LocalizedError, Equatable {
    case notFound
    case remoteSyncUnavailable

    var errorDescription: String? {
        switch self {
        case .notFound: "Patient ID not found on this device."
        case .remoteSyncUnavailable: "Secure remote patient sync is not configured."
        }
    }
}

@MainActor
protocol PatientDataProviding: AnyObject {
    func snapshot(for patientID: String) async throws -> PatientSnapshot
}

@MainActor
final class LocalPatientDataProvider: PatientDataProviding {
    private let identity: PatientIdentityStore
    private let prescriptions: PrescriptionStore
    private let history: EventHistoryStore

    init(
        identity: PatientIdentityStore,
        prescriptions: PrescriptionStore,
        history: EventHistoryStore
    ) {
        self.identity = identity
        self.prescriptions = prescriptions
        self.history = history
    }

    func snapshot(for patientID: String) async throws -> PatientSnapshot {
        guard PatientIdentityStore.normalize(patientID) == identity.patientID else {
            throw PatientLookupError.notFound
        }
        return PatientSnapshot(
            patientID: identity.patientID,
            prescriptions: prescriptions.prescriptions,
            history: history.records
        )
    }
}
