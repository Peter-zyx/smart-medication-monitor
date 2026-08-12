import SwiftUI

struct HomeView: View {
    @ObservedObject var viewModel: MedicationAppViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    connectionPill
                    medicationCard
                    flowCard
                }
                .padding(20)
            }
            .background(AppTheme.mist.ignoresSafeArea())
            .navigationTitle("MedBox")
            .navigationBarTitleDisplayMode(.inline)
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
            Text("Here is today’s medication event.")
                .foregroundStyle(.secondary)
        }
    }

    private var connectionPill: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(viewModel.connectionState.isReady ? AppTheme.teal : AppTheme.amber)
                .frame(width: 9, height: 9)
            Text(viewModel.connectionState.label)
                .font(.subheadline.weight(.semibold))
            Spacer()
            if viewModel.isSimulation {
                Text("SIMULATION")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.teal)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.white.opacity(0.8))
        .clipShape(Capsule())
    }

    private var medicationCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("TODAY’S MEDICATION")
                .font(.caption.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(AppTheme.teal)

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(viewModel.medication.name)
                        .font(.title2.bold())
                        .foregroundStyle(AppTheme.navy)
                    Text("\(viewModel.medication.expectedDose) \(doseUnit)")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(viewModel.medication.scheduledTime, format: .dateTime.hour().minute())
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(AppTheme.navy)
            }

            Button(action: viewModel.takeMedication) {
                Label("Take Medication", systemImage: "pill.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(AppTheme.teal)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .disabled(viewModel.flowState.isActive)
            .opacity(viewModel.flowState.isActive ? 0.55 : 1)
        }
        .medBoxCard()
    }

    @ViewBuilder
    private var flowCard: some View {
        if viewModel.flowState != .idle {
            MedicationFlowView(state: viewModel.flowState, onDismiss: viewModel.resetFlow)
        }
    }

    private var greeting: String {
        Calendar.current.component(.hour, from: .now) < 12 ? "Good morning" : "Hello"
    }

    private var doseUnit: String {
        let base = viewModel.medication.unit
        return viewModel.medication.expectedDose == 1 ? base : "\(base)s"
    }
}

