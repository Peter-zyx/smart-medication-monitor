import Foundation

public enum BLEProtocol {
    public static let deviceName = "MedBox-S3"
    public static let serviceUUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
    public static let rxUUID = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
    public static let txUUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
}

public enum BLECommand: Equatable, Sendable {
    case open
    case status
    case weight
    case zero
    case mode(DeviceMode)
    case learn(name: String, count: Int, dose: Int)
    case label(MedicationPrediction)

    public var wireValue: String {
        switch self {
        case .open: "OPEN"
        case .status: "STATUS"
        case .weight: "WEIGHT"
        case .zero: "ZERO"
        case let .mode(mode): "MODE|\(mode.rawValue)"
        case let .learn(name, count, dose): "LEARN|\(name)|\(count)|\(dose)"
        case let .label(prediction): "LABEL|\(prediction.rawValue)"
        }
    }
}

public enum DeviceMode: String, Codable, CaseIterable, Sendable {
    case live = "LIVE"
    case train = "TRAIN"
}

public enum MedicationPrediction: String, Codable, CaseIterable, Sendable {
    case one = "ONE"
    case two = "TWO"
    case none = "NONE"
    case returned = "RETURN"
    case disturbance = "DISTURBANCE"
    case uncertain = "UNCERTAIN"
}

public enum DeviceOperation: String, Codable, Sendable {
    case zero = "ZERO"
    case learn = "LEARN"
}

public struct MedicationStatus: Equatable, Sendable {
    public let name: String
    public let pillWeight: Double
    public let expectedDose: Int
    public let mode: DeviceMode

    public init(name: String, pillWeight: Double, expectedDose: Int, mode: DeviceMode) {
        self.name = name
        self.pillWeight = pillWeight
        self.expectedDose = expectedDose
        self.mode = mode
    }
}

public struct AIResult: Equatable, Sendable {
    public let eventID: Int
    public let prediction: MedicationPrediction
    public let finalDelta: Double
    public let confidence: Double?

    public init(
        eventID: Int,
        prediction: MedicationPrediction,
        finalDelta: Double,
        confidence: Double? = nil
    ) {
        self.eventID = eventID
        self.prediction = prediction
        self.finalDelta = finalDelta
        self.confidence = confidence
    }
}

public enum BLEMessage: Equatable, Sendable {
    case opened(eventID: Int)
    case closed(eventID: Int)
    case eventEnded(eventID: Int, removedWeight: Double)
    case ready(eventID: Int)
    case ai(AIResult)
    case weight(Double)
    case status(MedicationStatus)
    case mode(DeviceMode)
    case busy(DeviceOperation)
    case zeroed
    case learned(name: String, pillWeight: Double, expectedDose: Int)
    case error(code: String)
    case unknown(raw: String)
}

