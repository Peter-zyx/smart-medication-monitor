import SwiftUI

struct AddPrescriptionView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettingsStore

    @ObservedObject var store: PrescriptionStore
    let onSaved: () -> Void

    @State private var medicationName = ""
    @State private var dose = 1
    @State private var unit = "tablet"
    @State private var scheduledTime = Date.now

    var body: some View {
        NavigationStack {
            Form {
                Section(settings.text("Medication", "药物")) {
                    TextField(settings.text("Medication name", "药物名称"), text: $medicationName)
                        .textInputAutocapitalization(.words)
                    Stepper(
                        settings.text("Dose: \(dose)", "剂量：\(dose)"),
                        value: $dose,
                        in: 1...20
                    )
                    TextField(settings.text("Unit (for example, tablet)", "单位（例如：片）"), text: $unit)
                }

                Section(settings.text("Daily schedule", "每日时间")) {
                    DatePicker(
                        settings.text("Reminder time", "提醒时间"),
                        selection: $scheduledTime,
                        displayedComponents: .hourAndMinute
                    )
                    Text(settings.text(
                        "If there is no response, MedBox schedules another reminder every 15 minutes for the next 2 hours.",
                        "如果用户没有响应，MedBox 会在接下来的 2 小时内每 15 分钟再次提醒。"
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(settings.text("New prescription", "新增配方"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(settings.text("Cancel", "取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(settings.text("Save", "保存"), action: save)
                        .disabled(!isValid)
                }
            }
            .onAppear {
                if settings.language == .simplifiedChinese, unit == "tablet" {
                    unit = "片"
                }
            }
        }
    }

    private var isValid: Bool {
        !medicationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        let components = Calendar.current.dateComponents([.hour, .minute], from: scheduledTime)
        store.add(
            Prescription(
                medicationName: medicationName.trimmingCharacters(in: .whitespacesAndNewlines),
                dose: dose,
                unit: unit.trimmingCharacters(in: .whitespacesAndNewlines),
                hour: components.hour ?? 10,
                minute: components.minute ?? 0
            )
        )
        onSaved()
        dismiss()
    }
}
