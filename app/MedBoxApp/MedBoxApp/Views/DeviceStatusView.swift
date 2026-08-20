import SwiftUI

struct DeviceStatusView: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @ObservedObject var viewModel: MedicationAppViewModel

    var body: some View {
        NavigationStack {
            List {
                Section(settings.text("Connection", "连接")) {
                    LabeledContent(settings.text("Device", "设备"), value: BLEProtocol.deviceName)
                    LabeledContent(
                        settings.text("Status", "状态"),
                        value: viewModel.connectionState.label(language: settings.language)
                    )
                    if viewModel.isSimulation {
                        LabeledContent(
                            settings.text("Transport", "传输方式"),
                            value: settings.text("Simulation", "模拟")
                        )
                    }
                    Button(settings.text("Reconnect", "重新连接"), action: viewModel.reconnect)
                    Button(settings.text("Refresh status", "刷新状态"), action: viewModel.refreshStatus)
                        .disabled(!viewModel.connectionState.isReady)
                }

                if let status = viewModel.deviceStatus {
                    Section(settings.text("Medication configuration", "药物配置")) {
                        LabeledContent(settings.text("Medication", "药物"), value: status.name)
                        LabeledContent(
                            settings.text("Unit weight", "单片重量"),
                            value: status.pillWeight.formatted(.number.precision(.fractionLength(3))) + " g"
                        )
                        LabeledContent(settings.text("Expected dose", "预期剂量"), value: String(status.expectedDose))
                        LabeledContent(settings.text("Mode", "模式"), value: status.mode.rawValue)
                    }
                }

                if viewModel.isSimulation {
                    Section(settings.text("Simulation result", "模拟结果")) {
                        Picker(
                            settings.text("Next result", "下次结果"),
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

                Section(settings.text("Language", "语言")) {
                    Picker(settings.text("App language", "应用语言"), selection: $settings.language) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section(settings.text("On-device camera recognition", "手机端相机识别")) {
                    Toggle(
                        settings.text("Recognize actions on this iPhone", "在这台 iPhone 上识别动作"),
                        isOn: Binding(
                            get: { settings.usePhoneCamera },
                            set: { enabled in
                                settings.usePhoneCamera = enabled
                                if !enabled { viewModel.disconnectCamera() }
                            }
                        )
                    )
                    .disabled(viewModel.isSimulation)

                    LabeledContent(
                        settings.text("Camera status", "相机状态"),
                        value: viewModel.camera.state.label(language: settings.language)
                    )

                    LabeledContent(
                        settings.text("Recognition", "动作识别"),
                        value: viewModel.camera.inferenceState.label(language: settings.language)
                    )

                    if let frame = viewModel.camera.latestFrame {
                        Image(uiImage: frame)
                            .resizable()
                            .scaledToFill()
                            .aspectRatio(4 / 3, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .clipped()
                            .accessibilityLabel(settings.text(
                                "Live MedBox camera preview",
                                "MedBox 相机实时预览"
                            ))
                    }

                    if viewModel.camera.state.isStreaming {
                        Button(settings.text("Disconnect camera", "断开相机")) {
                            viewModel.disconnectCamera()
                        }
                    } else {
                        Button(settings.text("Test camera preview", "测试相机预览")) {
                            viewModel.testCameraConnection()
                        }
                        .disabled(viewModel.isSimulation || viewModel.camera.state.isConnecting)
                    }

                    Text(settings.text(
                        "The ESP32 camera supports one viewer. Close the Mac camera script and browser previews; the iPhone now performs the action classification locally.",
                        "ESP32 相机目前只支持一个观看端。请关闭 Mac 相机脚本和浏览器预览；动作分类现在会在 iPhone 本地完成。"
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Section(settings.text("Prototype architecture", "原型架构")) {
                    LabeledContent(
                        settings.text("Weight inference", "重量识别"),
                        value: settings.text("ESP32 on-device", "ESP32 本地运行")
                    )
                    LabeledContent(
                        settings.text("Camera inference", "相机识别"),
                        value: settings.text("iPhone on-device", "iPhone 本地运行")
                    )
                    Text(settings.text(
                        "The medication flow no longer requires a connected computer. Weight evidence is classified by the ESP32 and camera actions are classified by this iPhone.",
                        "用药流程不再需要连接电脑。重量证据由 ESP32 判断，相机动作由这台 iPhone 判断。"
                    ))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let error = viewModel.lastProtocolError {
                    Section(settings.text("Latest device message", "最新设备消息")) {
                        Text(error).foregroundStyle(AppTheme.amber)
                    }
                }
            }
            .navigationTitle(settings.text("Device", "设备"))
        }
    }
}
