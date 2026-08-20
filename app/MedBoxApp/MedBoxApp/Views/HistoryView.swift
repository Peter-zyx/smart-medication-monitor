import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @ObservedObject var history: EventHistoryStore

    var body: some View {
        NavigationStack {
            Group {
                if history.records.isEmpty {
                    ContentUnavailableView(
                        settings.text("No medication events", "暂无用药事件"),
                        systemImage: "clock.arrow.circlepath",
                        description: Text(settings.text(
                            "Completed device results will appear here.",
                            "设备完成的检测结果会显示在这里。"
                        ))
                    )
                } else {
                    List(history.records) { record in
                        HStack(spacing: 14) {
                            Image(systemName: record.prediction.presentation(language: settings.language).symbol)
                                .font(.title2)
                                .foregroundStyle(AppTheme.teal)
                                .frame(width: 34)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.prediction.presentation(language: settings.language).title)
                                    .font(.headline)
                                Text(settings.text(
                                    "\(record.medicationName) · \(record.expectedDose) tablet",
                                    "\(record.medicationName) · \(record.expectedDose) 片"
                                ))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                if record.isSupportedByMultipleSignals {
                                    Text(settings.text("Weight + camera signals", "重量 + 相机信号"))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(AppTheme.teal)
                                }
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
            .navigationTitle(settings.text("History", "历史记录"))
        }
    }
}
