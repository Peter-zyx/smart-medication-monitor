import Combine
import Foundation

@MainActor
final class PatientIdentityStore: ObservableObject {
    @Published private(set) var patientID: String

    private let defaults: UserDefaults
    private let storageKey = "medbox.patient-id.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.string(forKey: storageKey), !stored.isEmpty {
            patientID = stored
        } else {
            let generated = Self.generateID()
            patientID = generated
            defaults.set(generated, forKey: storageKey)
        }
    }

    static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private static func generateID() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let token = String((0..<8).map { _ in alphabet.randomElement()! })
        return "MBX-\(token.prefix(4))-\(token.suffix(4))"
    }
}
