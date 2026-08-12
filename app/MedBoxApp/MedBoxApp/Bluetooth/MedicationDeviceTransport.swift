import Foundation

enum DeviceConnectionState: Equatable, Sendable {
    case bluetoothUnavailable
    case idle
    case scanning
    case connecting
    case discovering
    case ready
    case disconnected(reason: String?)

    var label: String {
        switch self {
        case .bluetoothUnavailable: "Bluetooth unavailable"
        case .idle: "Not connected"
        case .scanning: "Searching for MedBox-S3"
        case .connecting: "Connecting"
        case .discovering: "Preparing device"
        case .ready: "Connected"
        case let .disconnected(reason): reason ?? "Disconnected"
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

