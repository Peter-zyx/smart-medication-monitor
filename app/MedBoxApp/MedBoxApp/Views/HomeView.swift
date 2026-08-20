import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @ObservedObject var viewModel: MedicationAppViewModel
    @ObservedObject var prescriptionStore: PrescriptionStore
    @ObservedObject var reminders: MedicationReminderScheduler

    @State private var isAddingPrescription = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    connectionPill
                    reminderStatus
                    prescriptionSection
                    flowCard
                    cameraPreview
                    visionCard
                }
                .padding(20)
            }
            .background(AppTheme.mist.ignoresSafeArea())
            .navigationTitle("MedBox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isAddingPrescription = true
                    } label: {
                        Label(settings.text("Add prescription", "新增配方"), systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isAddingPrescription) {
                AddPrescriptionView(store: prescriptionStore) {
                    Task { await viewModel.refreshReminderSchedule(requestAuthorization: true) }
                }
            }
            .sheet(item: $viewModel.presentedEvent) { record in
                ResultView(record: record)
                    .presentationDetents([.large])
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(greeting)
                .font(.system(size: 31, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.navy)
            Text(settings.text("Here is today’s medication schedule.", "这是你今天的用药计划。"))
                .foregroundStyle(.secondary)
        }
    }

    private var connectionPill: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(viewModel.connectionState.isReady ? AppTheme.teal : AppTheme.amber)
                .frame(width: 9, height: 9)
            Text(viewModel.connectionState.label(language: settings.language))
                .font(.subheadline.weight(.semibold))
            Spacer()
            if viewModel.isSimulation {
                Text(settings.text("SIMULATION", "模拟"))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.teal)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.white.opacity(0.8))
        .clipShape(Capsule())
    }

    @ViewBuilder
    private var reminderStatus: some View {
        if reminders.authorizationState != .authorized {
            VStack(alignment: .leading, spacing: 12) {
                Label(
                    settings.text("Medication reminders", "用药提醒"),
                    systemImage: "bell.badge.fill"
                )
                .font(.headline)
                .foregroundStyle(AppTheme.navy)

                Text(reminders.authorizationState == .denied
                    ? settings.text(
                        "Notifications are disabled. Enable them in iPhone Settings to receive reminders.",
                        "通知已关闭。请前往 iPhone 设置开启通知，以接收用药提醒。"
                    )
                    : settings.text(
                        "Enable notifications for scheduled medication reminders.",
                        "开启通知以接收定时用药提醒。"
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if reminders.authorizationState == .unknown {
                    Button(settings.text("Enable reminders", "开启提醒")) {
                        Task { await viewModel.refreshReminderSchedule(requestAuthorization: true) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.teal)
                }
            }
            .medBoxCard()
        }
    }

    private var prescriptionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(settings.text("TODAY’S PRESCRIPTIONS", "今日处方"))
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(AppTheme.teal)
                Spacer()
                Button(settings.text("Add", "新增")) { isAddingPrescription = true }
                    .font(.subheadline.weight(.semibold))
            }

            if prescriptionStore.prescriptions.isEmpty {
                ContentUnavailableView(
                    settings.text("No prescriptions", "暂无处方"),
                    systemImage: "pills",
                    description: Text(settings.text(
                        "Add a medication and choose its daily reminder time.",
                        "添加药物并选择每天的提醒时间。"
                    ))
                )
            } else {
                ForEach(prescriptionStore.prescriptions) { prescription in
                    prescriptionCard(prescription)
                    if prescription.id != prescriptionStore.prescriptions.last?.id {
                        Divider()
                    }
                }
            }
        }
        .medBoxCard()
    }

    private func prescriptionCard(_ prescription: Prescription) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(prescription.medicationName)
                        .font(.title3.bold())
                        .foregroundStyle(AppTheme.navy)
                    Text(settings.text(
                        "\(prescription.dose) \(prescription.unit)",
                        "\(prescription.dose) \(prescription.unit)"
                    ))
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(timeText(prescription))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(AppTheme.navy)
            }

            Button {
                viewModel.takeMedication(prescription)
            } label: {
                Label(settings.text("Respond and open MedBox", "响应并打开 MedBox"), systemImage: "pill.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(AppTheme.teal)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .disabled(viewModel.flowState.isActive || !prescription.isEnabled)
            .opacity(viewModel.flowState.isActive || !prescription.isEnabled ? 0.55 : 1)
        }
    }

    @ViewBuilder
    private var flowCard: some View {
        if viewModel.flowState != .idle {
            MedicationFlowView(state: viewModel.flowState, onDismiss: viewModel.resetFlow)
        }
    }

    @ViewBuilder
    private var cameraPreview: some View {
        if settings.usePhoneCamera, viewModel.camera.state != .idle {
            CameraPreviewView(camera: viewModel.camera)
        }
    }

    @ViewBuilder
    private var visionCard: some View {
        if let result = viewModel.latestVisionResult {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: result.action.symbol)
                        .font(.title2)
                        .foregroundStyle(result.action == .take ? AppTheme.teal : AppTheme.amber)
                    Text(settings.text("CAMERA SIGNAL", "相机信号"))
                        .font(.caption.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(AppTheme.teal)
                    Spacer()
                    Text(result.confidence, format: .percent.precision(.fractionLength(0)))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                }

                Text(result.action.displayTitle(language: settings.language))
                    .font(.headline)
                    .foregroundStyle(AppTheme.navy)

                Text(settings.text(
                    "This is a visual action signal only and does not prove that medication was swallowed.",
                    "这只是视觉动作信号，不能证明药物已经被吞服。"
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .medBoxCard()
            .accessibilityElement(children: .combine)
        }
    }

    private var greeting: String {
        if Calendar.current.component(.hour, from: .now) < 12 {
            return settings.text("Good morning", "早上好")
        }
        return settings.text("Hello", "你好")
    }

    private func timeText(_ prescription: Prescription) -> String {
        var components = DateComponents()
        components.hour = prescription.hour
        components.minute = prescription.minute
        let date = Calendar.current.date(from: components) ?? .now
        return date.formatted(.dateTime.hour().minute())
    }
}
