import SwiftUI

@main
struct MedBoxApp: App {
    @StateObject private var viewModel: MedicationAppViewModel
    @StateObject private var settings: AppSettingsStore
    @StateObject private var prescriptions: PrescriptionStore
    @StateObject private var patientIdentity: PatientIdentityStore
    @StateObject private var reminders: MedicationReminderScheduler
    private let patientProvider: PatientDataProviding

    init() {
        let useMock = ProcessInfo.processInfo.arguments.contains("--mock-ble")
        let transport: MedicationDeviceTransport = useMock ? MockMedicationDevice() : BLEManager()
        let settings = AppSettingsStore()
        let prescriptions = PrescriptionStore()
        let patientIdentity = PatientIdentityStore()
        let reminders = MedicationReminderScheduler()
        let history = EventHistoryStore()
        let camera = MedBoxCameraManager()
        let viewModel = MedicationAppViewModel(
            transport: transport,
            history: history,
            prescriptionStore: prescriptions,
            reminderScheduler: reminders,
            settings: settings,
            camera: camera,
            isSimulation: useMock
        )
        reminders.onRespond = { [weak viewModel] id in
            viewModel?.respondToReminder(prescriptionID: id)
        }

        _settings = StateObject(wrappedValue: settings)
        _prescriptions = StateObject(wrappedValue: prescriptions)
        _patientIdentity = StateObject(wrappedValue: patientIdentity)
        _reminders = StateObject(wrappedValue: reminders)
        _viewModel = StateObject(wrappedValue: viewModel)
        patientProvider = LocalPatientDataProvider(
            identity: patientIdentity,
            prescriptions: prescriptions,
            history: history
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                viewModel: viewModel,
                prescriptions: prescriptions,
                patientIdentity: patientIdentity,
                reminders: reminders,
                patientProvider: patientProvider
            )
            .environmentObject(settings)
            .environment(\.locale, settings.language.locale)
        }
    }
}
