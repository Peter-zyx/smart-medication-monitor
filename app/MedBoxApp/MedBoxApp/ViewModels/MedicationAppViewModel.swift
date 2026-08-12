import Combine
import Foundation

@MainActor
final class MedicationAppViewModel: ObservableObject {
    enum FlowState: Equatable {
        case idle
        case connecting
        case opening
        case waiting
        case analyzing
        case failed(String)

        var message: String {
            switch self {
            case .idle: "Ready when you are"
            case .connecting: "Connecting to medication device…"
            case .opening: "Opening medication box…"
            case .waiting: "Waiting for medication interaction…"
            case .analyzing: "Analyzing medication event…"
            case let .failed(message): message
            }
        }

        var isActive: Bool {
            switch self {
            case .connecting, .opening, .waiting, .analyzing: true
            case .idle, .failed: false
            }
        }
    }

    @Published private(set) var connectionState: DeviceConnectionState = .idle
    @Published private(set) var flowState: FlowState = .idle
    @Published private(set) var deviceStatus: MedicationStatus?
    @Published private(set) var lastProtocolError: String?
    @Published var presentedEvent: MedicationEventRecord?
    @Published var medication = Medication.prototype
    @Published private(set) var simulationPrediction: MedicationPrediction = .one

    let history: EventHistoryStore
    let isSimulation: Bool

    private let transport: MedicationDeviceTransport
    private var pendingOpen = false

    init(
        transport: MedicationDeviceTransport,
        history: EventHistoryStore = EventHistoryStore(),
        isSimulation: Bool = false
    ) {
        self.transport = transport
        self.history = history
        self.isSimulation = isSimulation

        transport.onConnectionStateChange = { [weak self] state in
            self?.handleConnection(state)
        }
        transport.onMessage = { [weak self] message in
            self?.handle(message)
        }
        transport.onProtocolError = { [weak self] error in
            self?.lastProtocolError = error
            if self?.flowState.isActive == true { self?.flowState = .failed(error) }
        }
        transport.start()
    }

    func takeMedication() {
        lastProtocolError = nil
        guard connectionState.isReady else {
            pendingOpen = true
            flowState = .connecting
            transport.reconnect()
            return
        }
        sendOpen()
    }

    func reconnect() {
        lastProtocolError = nil
        transport.reconnect()
    }

    func refreshStatus() {
        try? transport.send(.status)
    }

    func selectSimulationPrediction(_ prediction: MedicationPrediction) {
        guard let mock = transport as? MockMedicationDevice else { return }
        simulationPrediction = prediction
        mock.nextPrediction = prediction
    }

    func resetFlow() {
        pendingOpen = false
        flowState = .idle
    }

    private func sendOpen() {
        do {
            try transport.send(.open)
            pendingOpen = false
            flowState = .opening
        } catch {
            flowState = .failed(error.localizedDescription)
        }
    }

    private func handleConnection(_ state: DeviceConnectionState) {
        connectionState = state
        if state.isReady, pendingOpen { sendOpen() }
    }

    private func handle(_ message: BLEMessage) {
        switch message {
        case .opened:
            flowState = .waiting
        case .closed, .eventEnded, .ready:
            flowState = .analyzing
        case let .ai(result):
            let record = MedicationEventRecord(
                eventID: result.eventID,
                medicationName: deviceStatus?.name ?? medication.name,
                expectedDose: deviceStatus?.expectedDose ?? medication.expectedDose,
                prediction: result.prediction,
                weightChange: result.finalDelta,
                confidence: result.confidence
            )
            history.add(record)
            presentedEvent = record
            flowState = .idle
        case let .status(status):
            deviceStatus = status
            medication.name = status.name
            medication.expectedDose = status.expectedDose
        case let .error(code):
            let message = humanReadableError(code)
            lastProtocolError = message
            flowState = .failed(message)
        case .mode, .weight, .busy, .zeroed, .learned, .unknown:
            break
        }
    }

    private func humanReadableError(_ code: String) -> String {
        switch code {
        case "BASELINE_WAIT": "The scale is rebuilding its baseline. Please wait about 3 seconds."
        case "ZERO_FIRST": "The scale must be zeroed before an event."
        case "LID_BUSY": "The medication device is already handling an event."
        default: "Device error: \(code)"
        }
    }
}
