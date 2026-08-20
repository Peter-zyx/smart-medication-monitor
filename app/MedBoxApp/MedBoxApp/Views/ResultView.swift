import SwiftUI

struct ResultView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettingsStore
    let record: MedicationEventRecord

    private var presentation: ResultPresentation {
        record.prediction.presentation(language: settings.language)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: presentation.symbol)
                    .font(.system(size: 68, weight: .semibold))
                    .foregroundStyle(toneColor)

                VStack(spacing: 10) {
                    Text(presentation.title)
                        .font(.system(size: 29, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(AppTheme.navy)
                    Text(presentation.message)
                        .font(.title3)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 14) {
                    metric(
                        settings.text("Weight change", "重量变化"),
                        value: record.weightChange.formatted(.number.precision(.fractionLength(3))) + " g"
                    )
                    if let confidence = record.confidence {
                        metric(
                            settings.text("Model confidence", "模型置信度"),
                            value: confidence.formatted(.percent.precision(.fractionLength(0)))
                        )
                    }
                    if let visionAction = record.visionAction {
                        metric(
                            settings.text("Camera signal", "相机信号"),
                            value: visionAction.displayTitle(language: settings.language)
                        )
                    }
                    if let visionConfidence = record.visionConfidence {
                        metric(
                            settings.text("Camera confidence", "相机置信度"),
                            value: visionConfidence.formatted(.percent.precision(.fractionLength(0)))
                        )
                    }
                }
                .medBoxCard()

                if record.isSupportedByMultipleSignals {
                    Label(
                        settings.text(
                            "Medication taking likely confirmed by multiple signals",
                            "多种信号共同支持可能已完成服药"
                        ),
                        systemImage: "checkmark.seal.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.teal)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(AppTheme.teal.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                Text(presentation.guidance)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Spacer()

                Button(settings.text("Done", "完成")) { dismiss() }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .foregroundStyle(.white)
                    .background(AppTheme.navy)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .padding(24)
            .background(AppTheme.mist.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(settings.text("Close", "关闭")) { dismiss() }
                }
            }
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.body.monospacedDigit().weight(.semibold))
        }
    }

    private var toneColor: Color {
        switch presentation.tone {
        case .positive: AppTheme.teal
        case .warning: AppTheme.amber
        case .neutral: .secondary
        }
    }
}
