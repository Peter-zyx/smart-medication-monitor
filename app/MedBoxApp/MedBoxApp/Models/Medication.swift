import Foundation

struct Medication: Codable, Equatable, Sendable {
    var name: String
    var expectedDose: Int
    var unit: String
    var scheduledTime: Date

    static var prototype: Medication {
        var components = DateComponents()
        components.hour = 10
        components.minute = 30

        return Medication(
            name: "TestDrug",
            expectedDose: 1,
            unit: "tablet",
            scheduledTime: Calendar.current.nextDate(
                after: .now,
                matching: components,
                matchingPolicy: .nextTime,
                direction: .forward
            ) ?? .now
        )
    }
}

