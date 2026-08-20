import Testing
@testable import MedBoxProtocol

struct BLEMessageParserTests {
    private let parser = BLEMessageParser()

    @Test func parsesEventLifecycle() throws {
        #expect(try parser.parse("O|12\n") == .opened(eventID: 12))
        #expect(try parser.parse("C|12") == .closed(eventID: 12))
        #expect(try parser.parse("E|12|0.842") == .eventEnded(eventID: 12, removedWeight: 0.842))
        #expect(try parser.parse("READY|12") == .ready(eventID: 12))
    }

    @Test func parsesAIWithoutConfidence() throws {
        #expect(
            try parser.parse("AI|12|ONE|0.842") ==
                .ai(AIResult(eventID: 12, prediction: .one, finalDelta: 0.842))
        )
    }

    @Test func parsesAIWithConfidence() throws {
        #expect(
            try parser.parse("AI|15|RETURN|-0.018|0.864") ==
                .ai(
                    AIResult(
                        eventID: 15,
                        prediction: .returned,
                        finalDelta: -0.018,
                        confidence: 0.864
                    )
                )
        )
    }

    @Test func parsesVisionResult() throws {
        #expect(
            try parser.parse("V|15|TAKE|0.824") ==
                .vision(VisionResult(eventID: 15, action: .take, confidence: 0.824))
        )
        #expect(
            try parser.parse("V|0|TOUCH_FACE|0.612") ==
                .vision(VisionResult(eventID: 0, action: .touchFace, confidence: 0.612))
        )
    }

    @Test func parsesStatusAndOperations() throws {
        #expect(
            try parser.parse("S|TestDrug|0.839|1|LIVE") ==
                .status(
                    MedicationStatus(
                        name: "TestDrug",
                        pillWeight: 0.839,
                        expectedDose: 1,
                        mode: .live
                    )
                )
        )
        #expect(try parser.parse("MODE|TRAIN") == .mode(.train))
        #expect(try parser.parse("BUSY|ZERO") == .busy(.zero))
        #expect(try parser.parse("OK|ZERO") == .zeroed)
        #expect(
            try parser.parse("OK|LEARN|TestDrug|0.848|1") ==
                .learned(name: "TestDrug", pillWeight: 0.848, expectedDose: 1)
        )
    }

    @Test func keepsUnknownMessagesForDiagnostics() throws {
        #expect(try parser.parse("FUTURE|value") == .unknown(raw: "FUTURE|value"))
        #expect(try parser.parse("ERR|BASELINE_WAIT") == .error(code: "BASELINE_WAIT"))
    }

    @Test func rejectsMalformedKnownMessages() {
        #expect(throws: BLEParseError.self) { try parser.parse("AI|abc|ONE|0.8") }
        #expect(throws: BLEParseError.self) { try parser.parse("AI|1|INVALID|0.8") }
        #expect(throws: BLEParseError.self) { try parser.parse("S|Drug|not-a-number|1|LIVE") }
        #expect(throws: BLEParseError.self) { try parser.parse("V|1|INVALID|0.8") }
        #expect(throws: BLEParseError.self) { try parser.parse("V|1|TAKE|1.2") }
        #expect(throws: BLEParseError.self) { try parser.parse("") }
    }

    @Test func serializesCommands() {
        #expect(BLECommand.open.wireValue == "OPEN")
        #expect(BLECommand.mode(.live).wireValue == "MODE|LIVE")
        #expect(BLECommand.learn(name: "TestDrug", count: 10, dose: 1).wireValue == "LEARN|TestDrug|10|1")
        #expect(BLECommand.label(.returned).wireValue == "LABEL|RETURN")
    }
}
