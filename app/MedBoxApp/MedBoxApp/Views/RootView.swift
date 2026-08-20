import SwiftUI

struct RootView: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @ObservedObject var viewModel: MedicationAppViewModel
    @ObservedObject var prescriptions: PrescriptionStore
    @ObservedObject var patientIdentity: PatientIdentityStore
    @ObservedObject var reminders: MedicationReminderScheduler
    let patientProvider: PatientDataProviding

    var body: some View {
        TabView {
            HomeView(
                viewModel: viewModel,
                prescriptionStore: prescriptions,
                reminders: reminders
            )
                .tabItem {
                    Label(settings.text("Home", "首页"), systemImage: "house.fill")
                }
            HistoryView(history: viewModel.history)
                .tabItem {
                    Label(settings.text("History", "历史"), systemImage: "clock.fill")
                }
            DoctorView(identity: patientIdentity, provider: patientProvider)
                .tabItem {
                    Label(settings.text("Doctor", "医生"), systemImage: "stethoscope")
                }
            DeviceStatusView(viewModel: viewModel)
                .tabItem {
                    Label(
                        settings.text("Device", "设备"),
                        systemImage: "sensor.tag.radiowaves.forward.fill"
                    )
                }
        }
        .tint(AppTheme.teal)
        .task { await viewModel.refreshReminderSchedule() }
        .onChange(of: settings.language) { _, _ in
            Task { await viewModel.refreshReminderSchedule() }
        }
    }
}
