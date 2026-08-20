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
        // ESP32 event IDs restart after a reboot. Only suppress a duplicate result
        // from the same recent event, not a legitimate event on a later day.
        guard !records.contains(where: {
            $0.eventID == record.eventID
                && abs($0.timestamp.timeIntervalSince(record.timestamp)) < 5 * 60
        }) else { return }
        records.insert(record, at: 0)
        persist()
    }

    func attachVision(_ result: VisionResult) {
        guard let index = records.firstIndex(where: { $0.eventID == result.eventID }) else {
            return
        }
        records[index] = records[index].attachingVision(result)
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
