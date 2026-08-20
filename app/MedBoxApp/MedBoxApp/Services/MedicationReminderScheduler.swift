import Combine
import Foundation
import UserNotifications

struct ReminderPlanBuilder {
    static let followUpInterval: TimeInterval = 15 * 60
    static let followUpCount = 8

    /// Distributes the remaining notification slots round-robin by follow-up
    /// number so one prescription cannot consume every slot before later
    /// prescriptions receive any follow-ups.
    static func followUpAllocation(
        prescriptionCount: Int,
        availableSlots: Int
    ) -> [(prescriptionIndex: Int, followUpIndex: Int)] {
        guard prescriptionCount > 0, availableSlots > 0 else { return [] }

        var allocation: [(prescriptionIndex: Int, followUpIndex: Int)] = []
        allocation.reserveCapacity(min(availableSlots, prescriptionCount * followUpCount))

        for followUpIndex in 1...followUpCount {
            for prescriptionIndex in 0..<prescriptionCount {
                guard allocation.count < availableSlots else { return allocation }
                allocation.append((prescriptionIndex, followUpIndex))
            }
        }
        return allocation
    }

    static func followUpDates(
        for prescription: Prescription,
        after date: Date = .now,
        calendar: Calendar = .current
    ) -> [Date] {
        let first = prescription.nextScheduledDate(after: date, calendar: calendar)
        return (1...followUpCount).map {
            first.addingTimeInterval(Double($0) * followUpInterval)
        }
    }
}

@MainActor
final class MedicationReminderScheduler: NSObject, ObservableObject {
    enum AuthorizationState: Equatable {
        case unknown
        case authorized
        case denied
    }

    nonisolated static let categoryIdentifier = "MEDBOX_MEDICATION_REMINDER"
    nonisolated static let respondActionIdentifier = "MEDBOX_RESPOND"
    nonisolated static let identifierPrefix = "medbox.reminder."
    nonisolated static let maximumManagedRequestCount = 60

    @Published private(set) var authorizationState: AuthorizationState = .unknown
    var onRespond: ((UUID) -> Void)?

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
        registerCategory(language: .english)
    }

    func refreshAuthorizationState() async {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            authorizationState = .authorized
        case .denied:
            authorizationState = .denied
        case .notDetermined:
            authorizationState = .unknown
        @unknown default:
            authorizationState = .unknown
        }
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            authorizationState = granted ? .authorized : .denied
            return granted
        } catch {
            authorizationState = .denied
            return false
        }
    }

    func reschedule(_ prescriptions: [Prescription], language: AppLanguage) async {
        registerCategory(language: language)
        await refreshAuthorizationState()
        guard authorizationState == .authorized else { return }

        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: pending.map(\.identifier).filter {
                $0.hasPrefix(Self.identifierPrefix)
            }
        )

        let enabledPrescriptions = Array(
            prescriptions.filter(\.isEnabled).prefix(Self.maximumManagedRequestCount)
        )

        // Reserve a daily reminder for every enabled prescription before using
        // the remaining iOS notification slots for follow-ups.
        var requestCount = 0
        for prescription in enabledPrescriptions {
            do {
                try await addDailyRequest(for: prescription, language: language)
                requestCount += 1
            } catch {
                continue
            }
        }

        let availableSlots = Self.maximumManagedRequestCount - requestCount
        let followUpDates = enabledPrescriptions.map {
            ReminderPlanBuilder.followUpDates(for: $0)
        }
        for slot in ReminderPlanBuilder.followUpAllocation(
            prescriptionCount: enabledPrescriptions.count,
            availableSlots: availableSlots
        ) {
            let prescription = enabledPrescriptions[slot.prescriptionIndex]
            let date = followUpDates[slot.prescriptionIndex][slot.followUpIndex - 1]
            do {
                try await addFollowUpRequest(
                    for: prescription,
                    date: date,
                    index: slot.followUpIndex,
                    language: language
                )
                requestCount += 1
            } catch {
                continue
            }
        }
    }

    func markResponded(
        to prescription: Prescription,
        allPrescriptions: [Prescription],
        language: AppLanguage
    ) async {
        let pending = await center.pendingNotificationRequests()
        let prescriptionPrefix = Self.identifierPrefix + prescription.id.uuidString
        center.removePendingNotificationRequests(
            withIdentifiers: pending.map(\.identifier).filter {
                $0.hasPrefix(prescriptionPrefix)
            }
        )
        await reschedule(allPrescriptions, language: language)
    }

    private func addDailyRequest(for prescription: Prescription, language: AppLanguage) async throws {
        let content = content(for: prescription, language: language, isFollowUp: false)
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: prescription.timeComponents,
            repeats: true
        )
        try await center.add(
            UNNotificationRequest(
                identifier: Self.identifierPrefix + prescription.id.uuidString + ".daily",
                content: content,
                trigger: trigger
            )
        )
    }

    private func addFollowUpRequest(
        for prescription: Prescription,
        date: Date,
        index: Int,
        language: AppLanguage
    ) async throws {
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: date
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        try await center.add(
            UNNotificationRequest(
                identifier: Self.identifierPrefix + prescription.id.uuidString + ".followup.\(index)",
                content: content(for: prescription, language: language, isFollowUp: true),
                trigger: trigger
            )
        )
    }

    private func content(
        for prescription: Prescription,
        language: AppLanguage,
        isFollowUp: Bool
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = language.text(
            isFollowUp ? "Medication reminder" : "It is time for your medication",
            isFollowUp ? "用药再次提醒" : "该服药了"
        )
        content.body = language.text(
            "\(prescription.medicationName): \(prescription.dose) \(prescription.unit). Open MedBox when you are ready.",
            "\(prescription.medicationName)：\(prescription.dose) \(prescription.unit)。准备好后请打开 MedBox。"
        )
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = ["prescription_id": prescription.id.uuidString]
        return content
    }

    private func registerCategory(language: AppLanguage) {
        let respond = UNNotificationAction(
            identifier: Self.respondActionIdentifier,
            title: language.text("Open MedBox", "打开 MedBox"),
            options: [.foreground]
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryIdentifier,
                actions: [respond],
                intentIdentifiers: [],
                options: []
            )
        ])
    }
}

extension MedicationReminderScheduler: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == Self.respondActionIdentifier
                || response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let rawID = response.notification.request.content.userInfo["prescription_id"] as? String,
              let id = UUID(uuidString: rawID)
        else { return }

        await MainActor.run { onRespond?(id) }
    }
}
