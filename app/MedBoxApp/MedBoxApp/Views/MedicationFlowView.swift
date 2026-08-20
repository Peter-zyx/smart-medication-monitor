import SwiftUI

struct MedicationFlowView: View {
    @EnvironmentObject private var settings: AppSettingsStore
    let state: MedicationAppViewModel.FlowState
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Group {
                if state.isActive {
                    ProgressView().tint(AppTheme.teal)
                } else {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(AppTheme.amber)
                }
            }
            .frame(width: 30, height: 30)

            Text(state.message(language: settings.language))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.navy)

            Spacer()

            if !state.isActive {
                Button(settings.text("Dismiss", "关闭"), action: onDismiss)
                    .font(.caption.weight(.bold))
            }
        }
        .medBoxCard()
    }
}
