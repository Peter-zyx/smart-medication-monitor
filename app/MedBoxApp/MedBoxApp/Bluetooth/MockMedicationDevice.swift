import Foundation

@MainActor
final class MockMedicationDevice: MedicationDeviceTransport {
    var onConnectionStateChange: ((DeviceConnectionState) -> Void)?
    var onMessage: ((BLEMessage) -> Void)?
    var onProtocolError: ((String) -> Void)?

    var nextPrediction: MedicationPrediction = .one
    private var nextEventID = 1
    private var isReady = false

    func start() {
        onConnectionStateChange?(.scanning)
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            isReady = true
            onConnectionStateChange?(.ready)
            onMessage?(
                .status(
                    MedicationStatus(name: "TestDrug", pillWeight: 0.848, expectedDose: 1, mode: .live)
                )
            )
        }
    }

    func reconnect() {
        start()
    }

    func send(_ command: BLECommand) throws {
        guard isReady else { throw DeviceTransportError.notReady }

        switch command {
        case .open:
            let eventID = nextEventID
            nextEventID += 1
            let prediction = nextPrediction
            Task {
                onMessage?(.opened(eventID: eventID))
                try? await Task.sleep(for: .milliseconds(650))
                onMessage?(.closed(eventID: eventID))
                try? await Task.sleep(for: .milliseconds(550))
                let delta = Self.delta(for: prediction)
                onMessage?(.eventEnded(eventID: eventID, removedWeight: delta))
                onMessage?(.ready(eventID: eventID))
                let vision = prediction == .one
                    ? VisionResult(eventID: eventID, action: .take, confidence: 0.82)
                    : VisionResult(eventID: eventID, action: .none, confidence: 0.79)
                onMessage?(.vision(vision))
                try? await Task.sleep(for: .milliseconds(600))
                onMessage?(
                    .ai(
                        AIResult(
                            eventID: eventID,
                            prediction: prediction,
                            finalDelta: delta,
                            confidence: Self.confidence(for: prediction)
                        )
                    )
                )
            }
        case .status:
            onMessage?(
                .status(
                    MedicationStatus(name: "TestDrug", pillWeight: 0.848, expectedDose: 1, mode: .live)
                )
            )
        case let .mode(mode): onMessage?(.mode(mode))
        case .weight: onMessage?(.weight(8.432))
        case .zero: onMessage?(.busy(.zero)); onMessage?(.zeroed)
        case let .learn(name, count, dose):
            onMessage?(.learned(name: name, pillWeight: 8.48 / Double(count), expectedDose: dose))
        case .label:
            onProtocolError?("Labels are not available in mock LIVE mode.")
        }
    }

    private static func delta(for prediction: MedicationPrediction) -> Double {
        switch prediction {
        case .one: 0.842
        case .two: 1.694
        case .none: 0.016
        case .returned: -0.018
        case .disturbance: 0.047
        case .uncertain: 0.355
        }
    }

    private static func confidence(for prediction: MedicationPrediction) -> Double? {
        switch prediction {
        case .none, .returned, .disturbance: 0.864
        case .one, .two, .uncertain: nil
        }
    }
}
