@preconcurrency import CoreBluetooth
import Foundation

@MainActor
final class BLEManager: NSObject, MedicationDeviceTransport {
    var onConnectionStateChange: ((DeviceConnectionState) -> Void)?
    var onMessage: ((BLEMessage) -> Void)?
    var onProtocolError: ((String) -> Void)?

    private let parser = BLEMessageParser()
    private let serviceUUID = CBUUID(string: BLEProtocol.serviceUUID)
    private let rxUUID = CBUUID(string: BLEProtocol.rxUUID)
    private let txUUID = CBUUID(string: BLEProtocol.txUUID)

    private lazy var central = CBCentralManager(delegate: self, queue: nil)
    private var peripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var txCharacteristic: CBCharacteristic?
    private var shouldReconnect = true
    private var state: DeviceConnectionState = .idle {
        didSet { onConnectionStateChange?(state) }
    }

    func start() {
        _ = central
    }

    func reconnect() {
        shouldReconnect = true
        guard central.state == .poweredOn else {
            state = .bluetoothUnavailable
            return
        }
        scan()
    }

    func send(_ command: BLECommand) throws {
        guard let peripheral, let rxCharacteristic else {
            throw DeviceTransportError.notReady
        }
        guard let data = command.wireValue.data(using: .utf8) else {
            throw DeviceTransportError.cannotEncode
        }

        let writeType: CBCharacteristicWriteType =
            rxCharacteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(data, for: rxCharacteristic, type: writeType)
    }

    private func scan() {
        guard !central.isScanning else { return }
        resetCharacteristics()
        state = .scanning
        central.scanForPeripherals(
            withServices: [serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func resetCharacteristics() {
        rxCharacteristic = nil
        txCharacteristic = nil
    }

    private func publishNotification(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else {
            onProtocolError?("Received a non-UTF-8 BLE notification.")
            return
        }

        let messages = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
        for raw in messages where !raw.isEmpty {
            do {
                onMessage?(try parser.parse(String(raw)))
            } catch {
                onProtocolError?("Could not parse ‘\(raw)’: \(error.localizedDescription)")
            }
        }
    }
}

extension BLEManager: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            scan()
        case .poweredOff, .unauthorized, .unsupported:
            state = .bluetoothUnavailable
        case .resetting, .unknown:
            state = .idle
        @unknown default:
            state = .bluetoothUnavailable
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard peripheral.name == BLEProtocol.deviceName || advertisedName == BLEProtocol.deviceName else {
            return
        }

        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        state = .connecting
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        state = .discovering
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        state = .disconnected(reason: error?.localizedDescription)
        if shouldReconnect { scan() }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        resetCharacteristics()
        state = .disconnected(reason: error?.localizedDescription)
        if shouldReconnect { scan() }
    }
}

extension BLEManager: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            onProtocolError?("Service discovery failed: \(error.localizedDescription)")
            return
        }

        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            onProtocolError?("The MedBox BLE service was not found.")
            return
        }
        peripheral.discoverCharacteristics([rxUUID, txUUID], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            onProtocolError?("Characteristic discovery failed: \(error.localizedDescription)")
            return
        }

        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == rxUUID { rxCharacteristic = characteristic }
            if characteristic.uuid == txUUID { txCharacteristic = characteristic }
        }

        guard rxCharacteristic != nil, let txCharacteristic else {
            onProtocolError?("The MedBox RX/TX characteristics were not found.")
            return
        }
        peripheral.setNotifyValue(true, for: txCharacteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            onProtocolError?("TX subscription failed: \(error.localizedDescription)")
            return
        }
        guard characteristic.uuid == txUUID, characteristic.isNotifying else { return }
        state = .ready
        try? send(.mode(.live))
        try? send(.status)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            onProtocolError?("BLE notification failed: \(error.localizedDescription)")
            return
        }
        guard characteristic.uuid == txUUID, let value = characteristic.value else { return }
        publishNotification(value)
    }
}
