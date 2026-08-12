import SwiftUI

struct RootView: View {
    @ObservedObject var viewModel: MedicationAppViewModel

    var body: some View {
        TabView {
            HomeView(viewModel: viewModel)
                .tabItem { Label("Home", systemImage: "house.fill") }
            HistoryView(history: viewModel.history)
                .tabItem { Label("History", systemImage: "clock.fill") }
            DeviceStatusView(viewModel: viewModel)
                .tabItem { Label("Device", systemImage: "sensor.tag.radiowaves.forward.fill") }
        }
        .tint(AppTheme.teal)
    }
}

