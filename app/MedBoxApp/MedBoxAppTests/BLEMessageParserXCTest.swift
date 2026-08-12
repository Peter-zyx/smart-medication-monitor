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
        XCTAssertEqual(try parser.parse("W|8.432"), .weight(8.432))
        XCTAssertEqual(try parser.parse("MODE|LIVE"), .mode(.live))
        XCTAssertEqual(try parser.parse("BUSY|ZERO"), .busy(.zero))
        XCTAssertEqual(try parser.parse("OK|ZERO"), .zeroed)
        XCTAssertEqual(try parser.parse("ERR|BASELINE_WAIT"), .error(code: "BASELINE_WAIT"))
    }

    func testRejectsMalformedKnownMessage() {
        XCTAssertThrowsError(try parser.parse("AI|not-an-id|ONE|0.842"))
    }
}

