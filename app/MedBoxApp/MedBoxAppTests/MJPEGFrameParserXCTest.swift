import XCTest
@testable import MedBoxApp

final class MJPEGFrameParserXCTest: XCTestCase {
    func testExtractsFramesAcrossArbitraryChunks() {
        var parser = MJPEGFrameParser()
        let first = Data([0xFF, 0xD8, 0x01, 0x02, 0xFF, 0xD9])
        let second = Data([0xFF, 0xD8, 0x03, 0x04, 0x05, 0xFF, 0xD9])

        XCTAssertTrue(parser.append(Data("multipart-header\r\n".utf8) + first.prefix(3)).isEmpty)
        let frames = parser.append(first.dropFirst(3) + Data("\r\n--boundary\r\n".utf8) + second)

        XCTAssertEqual(frames, [first, second])
        XCTAssertEqual(parser.bufferedByteCount, 0)
    }

    func testRetainsSplitStartMarkerWhenTrimmingOversizedGarbage() {
        var parser = MJPEGFrameParser(maximumBufferSize: 8)
        XCTAssertTrue(parser.append(Data(repeating: 0x11, count: 9) + Data([0xFF])).isEmpty)

        let frameTail = Data([0xD8, 0x42, 0xFF, 0xD9])
        XCTAssertEqual(parser.append(frameTail), [Data([0xFF]) + frameTail])
    }
}
