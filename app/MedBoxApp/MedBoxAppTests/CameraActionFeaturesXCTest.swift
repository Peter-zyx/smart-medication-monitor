import XCTest
@testable import MedBoxApp

final class CameraActionFeaturesXCTest: XCTestCase {
    func testTemporalSummaryOrderMatchesTrainingPipeline() throws {
        let summary = try CameraActionFeatureExtractor.temporalSummary([[1], [3]], bins: 2)
        XCTAssertEqual(summary.count, 10)
        let expected: [Float] = [2, 1, 1, 3, 2, 2, 1, 3, 1, 3]
        for (actual, wanted) in zip(summary, expected) {
            XCTAssertEqual(actual, wanted, accuracy: 0.000_001)
        }
    }

    func testProductionWindowProducesExpectedModelShape() throws {
        let frame = Array(repeating: Float(0.25), count: CameraActionFeatureExtractor.frameFeatureCount)
        let sequence = Array(repeating: frame, count: CameraActionFeatureExtractor.sampledFrames)
        let summary = try CameraActionFeatureExtractor.temporalSummary(sequence)
        XCTAssertEqual(summary.count, CameraActionFeatureExtractor.modelFeatureCount)
        XCTAssertTrue(summary.allSatisfy(\.isFinite))
    }
}
