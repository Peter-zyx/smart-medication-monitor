import XCTest
@testable import MedBoxApp

final class BLEMessageParserXCTest: XCTestCase {
    private let parser = BLEMessageParser()

    func testParsesAllRequiredMessageFamilies() throws {
        XCTAssertEqual(try parser.parse("O|1"), .opened(eventID: 1))
        XCTAssertEqual(try parser.parse("C|1"), .closed(eventID: 1))
        XCTAssertEqual(try parser.parse("E|1|0.842"), .eventEnded(eventID: 1, removedWeight: 0.842))
        XCTAssertEqual(try parser.parse("READY|1"), .ready(eventID: 1))
        XCTAssertEqual(
            try parser.parse("AI|1|RETURN|-0.018|0.864"),
            .ai(AIResult(eventID: 1, prediction: .returned, finalDelta: -0.018, confidence: 0.864))
        )
        XCTAssertEqual(
            try parser.parse("V|1|TAKE|0.824"),
            .vision(VisionResult(eventID: 1, action: .take, confidence: 0.824))
        )
        XCTAssertEqual(try parser.parse("W|8.432"), .weight(8.432))
        XCTAssertEqual(try parser.parse("MODE|LIVE"), .mode(.live))
        XCTAssertEqual(try parser.parse("BUSY|ZERO"), .busy(.zero))
        XCTAssertEqual(try parser.parse("OK|ZERO"), .zeroed)
        XCTAssertEqual(try parser.parse("ERR|BASELINE_WAIT"), .error(code: "BASELINE_WAIT"))
    }

    func testRejectsMalformedKnownMessage() {
        XCTAssertThrowsError(try parser.parse("AI|not-an-id|ONE|0.842"))
        XCTAssertThrowsError(try parser.parse("V|1|TAKE|not-a-confidence"))
    }

    func testVisionCanAttachAfterWeightResult() {
        let record = MedicationEventRecord(
            eventID: 9,
            medicationName: "TestDrug",
            expectedDose: 1,
            prediction: .one,
            weightChange: 0.842,
            confidence: nil
        )

        let updated = record.attachingVision(
            VisionResult(eventID: 9, action: .take, confidence: 0.82)
        )

        XCTAssertEqual(updated.id, record.id)
        XCTAssertEqual(updated.visionAction, .take)
        XCTAssertEqual(updated.visionConfidence, 0.82)
        XCTAssertTrue(updated.isSupportedByMultipleSignals)
    }

    func testMultipleSignalSupportRequiresExpectedRemovedCount() {
        let vision = VisionResult(eventID: 10, action: .take, confidence: 0.91)
        let expectedTwo = MedicationEventRecord(
            eventID: 10,
            medicationName: "TestDrug",
            expectedDose: 2,
            prediction: .two,
            weightChange: 1.696,
            confidence: nil
        ).attachingVision(vision)
        let unexpectedTwo = MedicationEventRecord(
            eventID: 10,
            medicationName: "TestDrug",
            expectedDose: 1,
            prediction: .two,
            weightChange: 1.696,
            confidence: nil
        ).attachingVision(vision)

        XCTAssertTrue(expectedTwo.isSupportedByMultipleSignals)
        XCTAssertFalse(unexpectedTwo.isSupportedByMultipleSignals)
    }
}

@MainActor
final class MedicationPlanningXCTest: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "MedBoxAppTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testPrescriptionStorePersistsDailyTime() {
        let store = PrescriptionStore(defaults: defaults, seedPrototype: false)
        let prescription = Prescription(
            medicationName: "Aspirin",
            dose: 2,
            unit: "tablets",
            hour: 8,
            minute: 45
        )

        store.add(prescription)
        let reloaded = PrescriptionStore(defaults: defaults, seedPrototype: false)

        XCTAssertEqual(reloaded.prescriptions, [prescription])
    }

    func testReminderPlanUsesFifteenMinuteIntervals() {
        let prescription = Prescription(
            medicationName: "TestDrug",
            dose: 1,
            unit: "tablet",
            hour: 10,
            minute: 0
        )
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 19,
            hour: 9,
            minute: 0
        ))!

        let dates = ReminderPlanBuilder.followUpDates(
            for: prescription,
            after: start,
            calendar: calendar
        )

        XCTAssertEqual(dates.count, 8)
        XCTAssertEqual(dates[0].timeIntervalSince(start), 75 * 60, accuracy: 0.1)
        XCTAssertEqual(dates[1].timeIntervalSince(dates[0]), 15 * 60, accuracy: 0.1)
        XCTAssertEqual(dates.last!.timeIntervalSince(dates[0]), 105 * 60, accuracy: 0.1)
    }

    func testReminderAllocationDoesNotStarveLaterPrescriptions() {
        let allocation = ReminderPlanBuilder.followUpAllocation(
            prescriptionCount: 8,
            availableSlots: 52
        )

        XCTAssertEqual(allocation.count, 52)
        XCTAssertEqual(
            allocation.prefix(8).map(\.prescriptionIndex),
            Array(0..<8)
        )
        XCTAssertEqual(Set(allocation.map(\.prescriptionIndex)), Set(0..<8))
        XCTAssertEqual(allocation.last?.followUpIndex, 7)
    }

    func testReminderAllocationHonorsEmptyAndCapacityLimits() {
        XCTAssertTrue(ReminderPlanBuilder.followUpAllocation(
            prescriptionCount: 0,
            availableSlots: 20
        ).isEmpty)
        XCTAssertTrue(ReminderPlanBuilder.followUpAllocation(
            prescriptionCount: 3,
            availableSlots: 0
        ).isEmpty)

        let allocation = ReminderPlanBuilder.followUpAllocation(
            prescriptionCount: 2,
            availableSlots: 100
        )
        XCTAssertEqual(allocation.count, 16)
        XCTAssertEqual(allocation.last?.followUpIndex, 8)
    }

    func testPatientIdentityIsStableAndLocalLookupRequiresExactID() async throws {
        let identity = PatientIdentityStore(defaults: defaults)
        let firstID = identity.patientID
        XCTAssertTrue(firstID.range(
            of: #"^MBX-[A-Z2-9]{4}-[A-Z2-9]{4}$"#,
            options: .regularExpression
        ) != nil)
        XCTAssertEqual(PatientIdentityStore(defaults: defaults).patientID, firstID)

        let prescriptions = PrescriptionStore(defaults: defaults, seedPrototype: false)
        let history = EventHistoryStore(defaults: defaults)
        let provider = LocalPatientDataProvider(
            identity: identity,
            prescriptions: prescriptions,
            history: history
        )

        let snapshot = try await provider.snapshot(for: firstID.lowercased())
        XCTAssertEqual(snapshot.patientID, firstID)

        do {
            _ = try await provider.snapshot(for: "MBX-AAAA-BBBB")
            XCTFail("A different patient ID must not return local health data")
        } catch let error as PatientLookupError {
            XCTAssertEqual(error, .notFound)
        }
    }

    func testInAppLanguageChoicePersists() {
        let settings = AppSettingsStore(defaults: defaults)
        settings.language = .simplifiedChinese

        XCTAssertEqual(AppSettingsStore(defaults: defaults).language, .simplifiedChinese)
        XCTAssertEqual(settings.text("History", "历史"), "历史")
    }

    func testHistoryAllowsReusedEventIDAfterDeviceRebootWindow() {
        let history = EventHistoryStore(defaults: defaults)
        let first = MedicationEventRecord(
            eventID: 1,
            timestamp: Date(timeIntervalSince1970: 1_000),
            medicationName: "A",
            expectedDose: 1,
            prediction: .one,
            weightChange: 0.8,
            confidence: nil
        )
        let later = MedicationEventRecord(
            eventID: 1,
            timestamp: Date(timeIntervalSince1970: 2_000),
            medicationName: "A",
            expectedDose: 1,
            prediction: .one,
            weightChange: 0.8,
            confidence: nil
        )

        history.add(first)
        history.add(first)
        history.add(later)

        XCTAssertEqual(history.records.count, 2)
    }
}
