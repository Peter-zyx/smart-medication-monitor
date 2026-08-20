import Combine
import Foundation

@MainActor
final class MedicationAppViewModel: ObservableObject {
    enum FlowState: Equatable {
        case idle
        case connectingCamera
        case connecting
        case opening
        case waiting
        case analyzing
        case failed(String)

        func message(language: AppLanguage) -> String {
            switch self {
            case .idle: language.text("Ready when you are", "准备就绪")
            case .connectingCamera: language.text(
                "Connecting to the MedBox camera…",
                "正在连接 MedBox 相机……"
            )
            case .connecting: language.text("Connecting to medication device…", "正在连接用药设备……")
            case .opening: language.text("Opening medication box…", "正在打开药盒……")
            case .waiting: language.text("Waiting for medication interaction…", "正在等待用药操作……")
            case .analyzing: language.text("Analyzing medication event…", "正在分析用药事件……")
            case let .failed(message): message
            }
        }

        var isActive: Bool {
            switch self {
            case .connectingCamera, .connecting, .opening, .waiting, .analyzing: true
            case .idle, .failed: false
            }
        }
    }

    @Published private(set) var connectionState: DeviceConnectionState = .idle
    @Published private(set) var flowState: FlowState = .idle
    @Published private(set) var deviceStatus: MedicationStatus?
    @Published private(set) var lastProtocolError: String?
    @Published private(set) var latestVisionResult: VisionResult?
    @Published var presentedEvent: MedicationEventRecord?
    @Published var medication = Medication.prototype
    @Published private(set) var simulationPrediction: MedicationPrediction = .one

    let history: EventHistoryStore
    let prescriptionStore: PrescriptionStore
    let reminderScheduler: MedicationReminderScheduler
    let camera: MedBoxCameraManager
    let isSimulation: Bool

    private let transport: MedicationDeviceTransport
    private let settings: AppSettingsStore
    private var pendingOpen = false
    private var activePrescription: Prescription?
    private var preparationTask: Task<Void, Never>?

    init(
        transport: MedicationDeviceTransport,
        history: EventHistoryStore? = nil,
        prescriptionStore: PrescriptionStore? = nil,
        reminderScheduler: MedicationReminderScheduler? = nil,
        settings: AppSettingsStore? = nil,
        camera: MedBoxCameraManager? = nil,
        isSimulation: Bool = false
    ) {
        self.transport = transport
        self.history = history ?? EventHistoryStore()
        self.prescriptionStore = prescriptionStore ?? PrescriptionStore()
        self.reminderScheduler = reminderScheduler ?? MedicationReminderScheduler()
        self.settings = settings ?? AppSettingsStore()
        self.camera = camera ?? MedBoxCameraManager()
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
        self.camera.onVisionResult = { [weak self] result in
            self?.receiveVision(result)
        }
        transport.start()
    }

    func takeMedication() {
        takeMedication(prescriptionStore.enabledPrescriptions.first ?? .prototype)
    }

    func takeMedication(_ prescription: Prescription) {
        lastProtocolError = nil
        activePrescription = prescription
        preparationTask?.cancel()
        preparationTask = Task { [weak self] in
            guard let self else { return }
            await self.reminderScheduler.markResponded(
                to: prescription,
                allPrescriptions: self.prescriptionStore.prescriptions,
                language: self.settings.language
            )

            if self.settings.usePhoneCamera, !self.isSimulation {
                self.flowState = .connectingCamera
                do {
                    try await self.camera.connectAndStart()
                } catch is CancellationError {
                    return
                } catch {
                    self.flowState = .failed(self.cameraFailureMessage(error))
                    return
                }
            }

            self.openWhenReady()
        }
    }

    private func openWhenReady() {
        guard connectionState.isReady else {
            pendingOpen = true
            flowState = .connecting
            transport.reconnect()
            return
        }
        sendOpen()
    }

    func respondToReminder(prescriptionID: UUID) {
        guard let prescription = prescriptionStore.prescription(id: prescriptionID) else { return }
        takeMedication(prescription)
    }

    func refreshReminderSchedule(requestAuthorization: Bool = false) async {
        if requestAuthorization, reminderScheduler.authorizationState == .unknown {
            _ = await reminderScheduler.requestAuthorization()
        }
        await reminderScheduler.reschedule(
            prescriptionStore.prescriptions,
            language: settings.language
        )
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
        preparationTask?.cancel()
        preparationTask = nil
        pendingOpen = false
        if settings.usePhoneCamera { camera.disconnect() }
        flowState = .idle
    }

    func testCameraConnection() {
        guard !isSimulation else { return }
        Task {
            do {
                try await camera.connectAndStart()
            } catch is CancellationError {
                return
            } catch {
                lastProtocolError = cameraFailureMessage(error)
            }
        }
    }

    func disconnectCamera() {
        camera.disconnect()
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
        case let .opened(eventID):
            latestVisionResult = nil
            if settings.usePhoneCamera { camera.beginActionRecognition(eventID: eventID) }
            flowState = .waiting
        case .closed, .eventEnded, .ready:
            flowState = .analyzing
        case let .ai(result):
            let matchingVision = latestVisionResult.flatMap { vision in
                vision.eventID == result.eventID ? vision : nil
            }
            let record = MedicationEventRecord(
                eventID: result.eventID,
                medicationName: activePrescription?.medicationName
                    ?? deviceStatus?.name
                    ?? medication.name,
                expectedDose: activePrescription?.dose
                    ?? deviceStatus?.expectedDose
                    ?? medication.expectedDose,
                prediction: result.prediction,
                weightChange: result.finalDelta,
                confidence: result.confidence,
                visionAction: matchingVision?.action,
                visionConfidence: matchingVision?.confidence
            )
            history.add(record)
            presentedEvent = record
            activePrescription = nil
            if settings.usePhoneCamera { camera.finishActionRecognition() }
            flowState = .idle
        case let .vision(result):
            receiveVision(result)
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
        case "BASELINE_WAIT": settings.language.text(
            "The scale is rebuilding its baseline. Please wait about 3 seconds.",
            "电子秤正在重建基线，请等待约 3 秒。"
        )
        case "ZERO_FIRST": settings.language.text(
            "The scale must be zeroed before an event.",
            "开始用药事件前必须先将电子秤归零。"
        )
        case "LID_BUSY": settings.language.text(
            "The medication device is already handling an event.",
            "用药设备正在处理另一个事件。"
        )
        default: settings.language.text("Device error: \(code)", "设备错误：\(code)")
        }
    }

    private func cameraFailureMessage(_ error: Error) -> String {
        settings.language.text(
            "Camera connection failed: \(error.localizedDescription)",
            "相机连接失败：\(error.localizedDescription)"
        )
    }

    private func receiveVision(_ result: VisionResult) {
        latestVisionResult = result
        history.attachVision(result)
        if let record = presentedEvent, record.eventID == result.eventID {
            presentedEvent = record.attachingVision(result)
        }
    }
}
