import Foundation

struct Prescription: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var medicationName: String
    var dose: Int
    var unit: String
    var hour: Int
    var minute: Int
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        medicationName: String,
        dose: Int,
        unit: String,
        hour: Int,
        minute: Int,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.medicationName = medicationName
        self.dose = dose
        self.unit = unit
        self.hour = hour
        self.minute = minute
        self.isEnabled = isEnabled
    }

    var timeComponents: DateComponents {
        DateComponents(hour: hour, minute: minute)
    }

    func nextScheduledDate(after date: Date = .now, calendar: Calendar = .current) -> Date {
        calendar.nextDate(
            after: date,
            matching: timeComponents,
            matchingPolicy: .nextTime,
            direction: .forward
        ) ?? date.addingTimeInterval(24 * 60 * 60)
    }

    static var prototype: Prescription {
        Prescription(
            medicationName: "TestDrug",
            dose: 1,
            unit: "tablet",
            hour: 10,
            minute: 30
        )
    }
}
