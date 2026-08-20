import SwiftUI

struct DoctorView: View {
    @EnvironmentObject private var settings: AppSettingsStore

    @ObservedObject var identity: PatientIdentityStore
    let provider: PatientDataProviding

    @State private var enteredID = ""
    @State private var snapshot: PatientSnapshot?
    @State private var errorMessage: String?
    @State private var isSearching = false

    var body: some View {
        NavigationStack {
            List {
                Section(settings.text("Patient access", "患者查询")) {
                    TextField(settings.text("Patient ID", "患者 ID"), text: $enteredID)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Button(action: lookup) {
                        HStack {
                            if isSearching { ProgressView() }
                            Text(settings.text("View patient record", "查看患者记录"))
                        }
                    }
                    .disabled(enteredID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
                }

                Section(settings.text("This device’s patient ID", "本机患者 ID")) {
                    LabeledContent(settings.text("Patient ID", "患者 ID"), value: identity.patientID)
                        .textSelection(.enabled)
                    Text(settings.text(
                        "Share this ID only with an authorized care professional.",
                        "仅向已获授权的医护人员提供此 ID。"
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                if let snapshot {
                    prescriptionSection(snapshot)
                    historySections(snapshot)
                }

                if let errorMessage {
                    Section(settings.text("Lookup result", "查询结果")) {
                        Text(errorMessage).foregroundStyle(AppTheme.amber)
                    }
                }

                Section(settings.text("Prototype privacy boundary", "原型隐私边界")) {
                    Text(settings.text(
                        "This build supports on-device lookup only. Secure cross-device doctor access still requires authenticated cloud sync and explicit patient authorization.",
                        "当前版本仅支持本机查询。医生跨设备访问仍需要带身份认证的云同步和患者明确授权。"
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(settings.text("Doctor", "医生"))
        }
    }

    private func prescriptionSection(_ snapshot: PatientSnapshot) -> some View {
        Section(settings.text("Prescriptions", "处方内容")) {
            if snapshot.prescriptions.isEmpty {
                Text(settings.text("No prescriptions", "暂无处方"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.prescriptions) { prescription in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(prescription.medicationName).font(.headline)
                        Text(settings.text(
                            "\(prescription.dose) \(prescription.unit) daily at \(timeText(prescription))",
                            "每日 \(timeText(prescription))，\(prescription.dose) \(prescription.unit)"
                        ))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func historySections(_ snapshot: PatientSnapshot) -> some View {
        let grouped = Dictionary(grouping: snapshot.history) {
            Calendar.current.startOfDay(for: $0.timestamp)
        }
        if grouped.isEmpty {
            Section(settings.text("Medication history", "服药历史")) {
                Text(settings.text("No medication events", "暂无服药事件"))
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(grouped.keys.sorted(by: >), id: \.self) { date in
                Section(date.formatted(.dateTime.year().month().day())) {
                    ForEach(grouped[date] ?? []) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.medicationName).font(.headline)
                            Text(record.prediction.presentation(language: settings.language).title)
                            Text(record.timestamp, format: .dateTime.hour().minute())
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func lookup() {
        isSearching = true
        errorMessage = nil
        snapshot = nil
        Task {
            do {
                snapshot = try await provider.snapshot(for: enteredID)
            } catch {
                errorMessage = settings.text(
                    "Patient ID was not found on this device.",
                    "在本机未找到该患者 ID。"
                )
            }
            isSearching = false
        }
    }

    private func timeText(_ prescription: Prescription) -> String {
        var components = DateComponents()
        components.hour = prescription.hour
        components.minute = prescription.minute
        let date = Calendar.current.date(from: components) ?? .now
        return date.formatted(.dateTime.hour().minute())
    }
}
