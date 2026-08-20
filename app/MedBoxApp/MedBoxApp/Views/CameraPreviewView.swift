import SwiftUI

struct CameraPreviewView: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @ObservedObject var camera: MedBoxCameraManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "camera.fill")
                    .foregroundStyle(camera.state.isStreaming ? AppTheme.teal : AppTheme.amber)
                Text(settings.text("MEDBOX CAMERA", "MEDBOX 相机"))
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(AppTheme.teal)
                Spacer()
                Text(camera.state.label(language: settings.language))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Group {
                if let frame = camera.latestFrame {
                    Image(uiImage: frame)
                        .resizable()
                        .scaledToFill()
                        .accessibilityLabel(settings.text("Live MedBox camera preview", "MedBox 相机实时预览"))
                } else if case let .failed(message) = camera.state {
                    VStack(spacing: 12) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.title)
                            .foregroundStyle(AppTheme.amber)
                        Text(message)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 12) {
                        ProgressView().tint(AppTheme.teal)
                        Text(settings.text("Waiting for the first camera frame…", "正在等待相机首帧……"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(4 / 3, contentMode: .fit)
            .background(AppTheme.navy.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipped()

            Label(
                camera.inferenceState.label(language: settings.language),
                systemImage: "brain.head.profile"
            )
            .font(.footnote.weight(.semibold))
            .foregroundStyle(AppTheme.navy)

            if camera.state.isStreaming {
                Button(settings.text("Disconnect camera", "断开相机")) {
                    camera.disconnect()
                }
                .font(.subheadline.weight(.semibold))
            }

            Text(settings.text(
                "Action recognition runs on this iPhone. Frames stay on the local network and are not saved.",
                "动作识别直接在这台 iPhone 上运行。画面只在本地网络传输，不会保存。"
            ))
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .medBoxCard()
    }
}
