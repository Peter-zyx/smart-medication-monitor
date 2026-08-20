import CoreML
import Foundation
#if canImport(MediaPipeTasksVision)
import MediaPipeTasksVision
#endif
import UIKit

struct CameraActionPrediction: Equatable, Sendable {
    let eventID: Int
    let action: VisionAction
    let confidence: Double
}

enum CameraInferenceState: Equatable {
    case idle
    case collecting(current: Int, total: Int)
    case analyzing
    case result(VisionAction, Double)
    case failed(String)

    func label(language: AppLanguage) -> String {
        switch self {
        case .idle:
            language.text("Waiting for an event", "正在等待事件")
        case let .collecting(current, total):
            language.text("Analyzing frames \(current)/\(total)", "正在分析画面 \(current)/\(total)")
        case .analyzing:
            language.text("Classifying action", "正在识别动作")
        case let .result(action, confidence):
            "\(action.displayTitle(language: language)) \(Int((confidence * 100).rounded()))%"
        case let .failed(message):
            language.text("Recognition unavailable: \(message)", "动作识别不可用：\(message)")
        }
    }
}

enum CameraActionInferenceError: LocalizedError {
    case missingResource(String)
    case invalidModelOutput

    var errorDescription: String? {
        switch self {
        case let .missingResource(name): "Missing bundled camera model: \(name)"
        case .invalidModelOutput: "The camera action model returned an invalid result."
        }
    }
}

#if canImport(MediaPipeTasksVision)
final class CameraActionInferenceEngine: @unchecked Sendable {
    @MainActor var onStateChange: ((CameraInferenceState) -> Void)?
    @MainActor var onPrediction: ((CameraActionPrediction) -> Void)?

    private let worker = DispatchQueue(label: "MedBox.CameraActionInference", qos: .userInitiated)
    @MainActor private var activeEventID: Int?
    @MainActor private var isProcessingFrame = false
    @MainActor private var lastAcceptedFrameAt = Date.distantPast
    private let minimumFrameInterval: TimeInterval = 0.18
    private let confidenceThreshold = 0.40

    @MainActor
    func beginEvent(eventID: Int) {
        activeEventID = eventID
        lastAcceptedFrameAt = .distantPast
        onStateChange?(.collecting(current: 0, total: CameraActionFeatureExtractor.sampledFrames))
        worker.async { [weak self] in
            self?.resetWorkerState(eventID: eventID)
        }
    }

    @MainActor
    func consume(_ image: UIImage) {
        guard let eventID = activeEventID,
              !isProcessingFrame,
              Date().timeIntervalSince(lastAcceptedFrameAt) >= minimumFrameInterval else { return }
        isProcessingFrame = true
        lastAcceptedFrameAt = .now

        worker.async { [weak self] in
            guard let self else { return }
            do {
                let update = try self.process(image: image, eventID: eventID)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isProcessingFrame = false
                    guard self.activeEventID == eventID else { return }
                    switch update {
                    case let .collecting(count):
                        self.onStateChange?(.collecting(
                            current: count,
                            total: CameraActionFeatureExtractor.sampledFrames
                        ))
                    case .analyzing:
                        self.onStateChange?(.analyzing)
                    case let .prediction(prediction):
                        self.onStateChange?(.result(prediction.action, prediction.confidence))
                        self.onPrediction?(prediction)
                    }
                }
            } catch {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isProcessingFrame = false
                    guard self.activeEventID == eventID else { return }
                    self.onStateChange?(.failed(error.localizedDescription))
                }
            }
        }
    }

    @MainActor
    func endEvent() {
        activeEventID = nil
        isProcessingFrame = false
        worker.async { [weak self] in self?.resetWorkerState(eventID: nil) }
        onStateChange?(.idle)
    }

    private enum WorkerUpdate {
        case collecting(Int)
        case analyzing
        case prediction(CameraActionPrediction)
    }

    private var workerEventID: Int?
    private var frameVectors: [[Float]] = []
    private var poseLandmarker: PoseLandmarker?
    private var handLandmarker: HandLandmarker?
    private var classifier: MLModel?

    private func resetWorkerState(eventID: Int?) {
        workerEventID = eventID
        frameVectors.removeAll(keepingCapacity: true)
    }

    private func prepareIfNeeded() throws {
        if poseLandmarker == nil {
            guard let path = Bundle.main.path(forResource: "pose_landmarker_lite", ofType: "task") else {
                throw CameraActionInferenceError.missingResource("pose_landmarker_lite.task")
            }
            let options = PoseLandmarkerOptions()
            options.baseOptions.modelAssetPath = path
            options.runningMode = .image
            options.numPoses = 1
            options.minPoseDetectionConfidence = 0.35
            options.minPosePresenceConfidence = 0.35
            options.minTrackingConfidence = 0.35
            options.shouldOutputSegmentationMasks = false
            poseLandmarker = try PoseLandmarker(options: options)
        }
        if handLandmarker == nil {
            guard let path = Bundle.main.path(forResource: "hand_landmarker", ofType: "task") else {
                throw CameraActionInferenceError.missingResource("hand_landmarker.task")
            }
            let options = HandLandmarkerOptions()
            options.baseOptions.modelAssetPath = path
            options.runningMode = .image
            options.numHands = 2
            options.minHandDetectionConfidence = 0.30
            options.minHandPresenceConfidence = 0.30
            options.minTrackingConfidence = 0.30
            handLandmarker = try HandLandmarker(options: options)
        }
        if classifier == nil {
            guard let url = Bundle.main.url(
                forResource: "CameraActionClassifier",
                withExtension: "mlmodelc"
            ) else {
                throw CameraActionInferenceError.missingResource("CameraActionClassifier.mlmodelc")
            }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            classifier = try MLModel(contentsOf: url, configuration: configuration)
        }
    }

    private func process(image: UIImage, eventID: Int) throws -> WorkerUpdate {
        guard workerEventID == eventID else { return .collecting(0) }
        try prepareIfNeeded()
        guard let poseLandmarker, let handLandmarker else {
            throw CameraActionInferenceError.invalidModelOutput
        }
        let mediaPipeImage = try MPImage(uiImage: image)
        let poseResult = try poseLandmarker.detect(image: mediaPipeImage)
        let handResult = try handLandmarker.detect(image: mediaPipeImage)
        guard workerEventID == eventID else { return .collecting(0) }

        let pose = poseResult.landmarks.first?.map(Self.convert)
        let hands = handResult.landmarks.map { $0.map(Self.convert) }
        let vector = try CameraActionFeatureExtractor.frameFeatures(
            image: image,
            pose: pose,
            hands: hands
        )
        frameVectors.append(vector)
        if frameVectors.count > CameraActionFeatureExtractor.sampledFrames {
            frameVectors.removeFirst(frameVectors.count - CameraActionFeatureExtractor.sampledFrames)
        }
        guard frameVectors.count == CameraActionFeatureExtractor.sampledFrames else {
            return .collecting(frameVectors.count)
        }

        let summary = try CameraActionFeatureExtractor.temporalSummary(frameVectors)
        guard summary.count == CameraActionFeatureExtractor.modelFeatureCount else {
            throw CameraActionFeatureError.invalidFrameShape
        }
        return .prediction(try classify(summary, eventID: eventID))
    }

    private func classify(_ features: [Float], eventID: Int) throws -> CameraActionPrediction {
        guard let classifier else { throw CameraActionInferenceError.invalidModelOutput }
        let array = try MLMultiArray(
            shape: [NSNumber(value: CameraActionFeatureExtractor.modelFeatureCount)],
            dataType: .double
        )
        for (index, value) in features.enumerated() {
            array[index] = NSNumber(value: Double(value))
        }
        let input = try MLDictionaryFeatureProvider(dictionary: ["features": array])
        let output = try classifier.prediction(from: input)
        guard let rawLabel = output.featureValue(for: "label")?.stringValue,
              let probabilities = output.featureValue(for: "probabilities")?.dictionaryValue,
              let rawConfidence = probabilities[AnyHashable(rawLabel)]?.doubleValue else {
            throw CameraActionInferenceError.invalidModelOutput
        }
        let action = rawConfidence >= confidenceThreshold
            ? (VisionAction(rawValue: rawLabel) ?? .uncertain)
            : .uncertain
        return CameraActionPrediction(
            eventID: eventID,
            action: action,
            confidence: rawConfidence
        )
    }

    private static func convert(_ landmark: NormalizedLandmark) -> ActionLandmark {
        ActionLandmark(
            x: landmark.x,
            y: landmark.y,
            z: landmark.z,
            visibility: landmark.visibility?.floatValue ?? 0
        )
    }
}
#else
@MainActor
final class CameraActionInferenceEngine {
    var onStateChange: ((CameraInferenceState) -> Void)?
    var onPrediction: ((CameraActionPrediction) -> Void)?

    func beginEvent(eventID: Int) {
        onStateChange?(.failed(
            "MediaPipeTasksVision is not installed. Open MedBoxApp.xcworkspace after pod install."
        ))
    }

    func consume(_ image: UIImage) {}

    func endEvent() {
        onStateChange?(.idle)
    }
}
#endif
