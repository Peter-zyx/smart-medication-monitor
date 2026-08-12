import SwiftUI

struct ResultView: View {
    @Environment(\.dismiss) private var dismiss
    let record: MedicationEventRecord

    private var presentation: ResultPresentation { record.prediction.presentation }

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
                    metric("Weight change", value: record.weightChange.formatted(.number.precision(.fractionLength(3))) + " g")
                    if let confidence = record.confidence {
                        metric("Model confidence", value: confidence.formatted(.percent.precision(.fractionLength(0))))
                    }
                }
                .medBoxCard()

                Text(presentation.guidance)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Spacer()

                Button("Done") { dismiss() }
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
                    Button("Close") { dismiss() }
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

