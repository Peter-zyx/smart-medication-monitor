import SwiftUI

@main
struct MedBoxApp: App {
    @StateObject private var viewModel: MedicationAppViewModel

    init() {
        let useMock = ProcessInfo.processInfo.arguments.contains("--mock-ble")
        let transport: MedicationDeviceTransport = useMock ? MockMedicationDevice() : BLEManager()
        _viewModel = StateObject(
            wrappedValue: MedicationAppViewModel(transport: transport, isSimulation: useMock)
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView(viewModel: viewModel)
        }
    }
}

