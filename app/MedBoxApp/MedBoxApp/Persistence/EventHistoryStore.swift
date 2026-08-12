import Combine
import Foundation

@MainActor
final class EventHistoryStore: ObservableObject {
    @Published private(set) var records: [MedicationEventRecord] = []

    private let defaults: UserDefaults
    private let storageKey = "medbox.event-history.v1"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func add(_ record: MedicationEventRecord) {
        guard !records.contains(where: { $0.eventID == record.eventID }) else { return }
        records.insert(record, at: 0)
        persist()
    }

    func clear() {
        records = []
        defaults.removeObject(forKey: storageKey)
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey) else { return }
        records = (try? decoder.decode([MedicationEventRecord].self, from: data)) ?? []
    }

    private func persist() {
        guard let data = try? encoder.encode(records) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

