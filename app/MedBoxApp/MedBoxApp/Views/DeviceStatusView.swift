import SwiftUI

struct DeviceStatusView: View {
    @ObservedObject var viewModel: MedicationAppViewModel

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    LabeledContent("Device", value: BLEProtocol.deviceName)
                    LabeledContent("Status", value: viewModel.connectionState.label)
                    if viewModel.isSimulation {
                        LabeledContent("Transport", value: "Simulation")
                    }
                    Button("Reconnect", action: viewModel.reconnect)
                    Button("Refresh status", action: viewModel.refreshStatus)
                        .disabled(!viewModel.connectionState.isReady)
                }

                if let status = viewModel.deviceStatus {
                    Section("Medication configuration") {
                        LabeledContent("Medication", value: status.name)
                        LabeledContent("Unit weight", value: status.pillWeight.formatted(.number.precision(.fractionLength(3))) + " g")
                        LabeledContent("Expected dose", value: String(status.expectedDose))
                        LabeledContent("Mode", value: status.mode.rawValue)
                    }
                }

                if viewModel.isSimulation {
                    Section("Simulation result") {
                        Picker(
                            "Next result",
                            selection: Binding(
                                get: { viewModel.simulationPrediction },
                                set: viewModel.selectSimulationPrediction
                            )
                        ) {
                            ForEach(MedicationPrediction.allCases, id: \.self) { prediction in
                                Text(prediction.rawValue).tag(prediction)
                            }
                        }
                    }
                }

                Section("Prototype architecture") {
                    Text("AI inference currently runs on a connected Mac or PC over USB Serial. The iPhone receives the compact result through the ESP32 BLE link.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let error = viewModel.lastProtocolError {
                    Section("Latest device message") {
                        Text(error).foregroundStyle(AppTheme.amber)
                    }
                }
            }
            .navigationTitle("Device")
        }
    }
}
