import SwiftUI

struct HistoryView: View {
    @ObservedObject var history: EventHistoryStore

    var body: some View {
        NavigationStack {
            Group {
                if history.records.isEmpty {
                    ContentUnavailableView(
                        "No medication events",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Completed device results will appear here.")
                    )
                } else {
                    List(history.records) { record in
                        HStack(spacing: 14) {
                            Image(systemName: record.prediction.presentation.symbol)
                                .font(.title2)
                                .foregroundStyle(AppTheme.teal)
                                .frame(width: 34)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.prediction.presentation.title)
                                    .font(.headline)
                                Text("\(record.medicationName) · \(record.expectedDose) tablet")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(record.timestamp, format: .dateTime.hour().minute())
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 7)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("History")
        }
    }
}

