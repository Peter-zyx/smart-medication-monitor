import Combine
import Foundation

@MainActor
final class PrescriptionStore: ObservableObject {
    @Published private(set) var prescriptions: [Prescription] = []

    private let defaults: UserDefaults
    private let storageKey = "medbox.prescriptions.v1"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard, seedPrototype: Bool = true) {
        self.defaults = defaults
        load()
        if prescriptions.isEmpty, seedPrototype {
            prescriptions = [.prototype]
            persist()
        }
    }

    var enabledPrescriptions: [Prescription] {
        prescriptions.filter(\.isEnabled)
    }

    func add(_ prescription: Prescription) {
        prescriptions.append(prescription)
        sortAndPersist()
    }

    func update(_ prescription: Prescription) {
        guard let index = prescriptions.firstIndex(where: { $0.id == prescription.id }) else {
            return
        }
        prescriptions[index] = prescription
        sortAndPersist()
    }

    func remove(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            prescriptions.remove(at: index)
        }
        persist()
    }

    func prescription(id: UUID) -> Prescription? {
        prescriptions.first(where: { $0.id == id })
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey) else { return }
        prescriptions = (try? decoder.decode([Prescription].self, from: data)) ?? []
    }

    private func sortAndPersist() {
        prescriptions.sort { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
        persist()
    }

    private func persist() {
        guard let data = try? encoder.encode(prescriptions) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
