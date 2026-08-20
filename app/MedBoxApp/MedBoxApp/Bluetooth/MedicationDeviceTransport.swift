import Foundation

enum DeviceConnectionState: Equatable, Sendable {
    case bluetoothUnavailable
    case idle
    case scanning
    case connecting
    case discovering
    case ready
    case disconnected(reason: String?)

    func label(language: AppLanguage) -> String {
        switch self {
        case .bluetoothUnavailable: language.text("Bluetooth unavailable", "蓝牙不可用")
        case .idle: language.text("Not connected", "未连接")
        case .scanning: language.text("Searching for MedBox-S3", "正在搜索 MedBox-S3")
        case .connecting: language.text("Connecting", "正在连接")
        case .discovering: language.text("Preparing device", "正在准备设备")
        case .ready: language.text("Connected", "已连接")
        case let .disconnected(reason): reason ?? language.text("Disconnected", "连接已断开")
        }
    }

    var isReady: Bool { self == .ready }
}

@MainActor
protocol MedicationDeviceTransport: AnyObject {
    var onConnectionStateChange: ((DeviceConnectionState) -> Void)? { get set }
    var onMessage: ((BLEMessage) -> Void)? { get set }
    var onProtocolError: ((String) -> Void)? { get set }

    func start()
    func reconnect()
    func send(_ command: BLECommand) throws
}

enum DeviceTransportError: LocalizedError {
    case notReady
    case cannotEncode

    var errorDescription: String? {
        switch self {
        case .notReady: "The medication device is not ready."
        case .cannotEncode: "The command could not be encoded."
        }
    }
}
