import CoreBluetooth
import Combine

/// Manages the BLE connection to Bose headphones using CoreBluetooth directly.
/// Replaces the Rust daemon + Unix socket IPC for the App Store build.
final class BleManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var state = HeadphoneState()
    @Published var statusMessage: String? = "Initializing Bluetooth..."

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var bmapChar: CBCharacteristic?
    private var reassembler = BmapReassembler()

    // UUIDs matching the Rust daemon
    private static let bmapServiceUUID = CBUUID(string: "0000FEBE-0000-0000-0000-000000000000")
    private static let secureCharUUID = CBUUID(string: "C65B8F2F-AEE2-4C89-B758-BC4892D6F2D8")
    private static let unsecureCharUUID = CBUUID(string: "D417C028-9818-4354-99D1-2AC09D074591")

    private static let boseNamePatterns = ["bose", "adjuster"]

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil) // nil = main queue
    }

    // MARK: - Public API

    func setAudioMode(_ index: UInt8) { send(BmapProtocol.setCurrentMode(index)) }
    func setStandbyTimer(_ minutes: UInt8) { send(BmapProtocol.setStandbyTimer(minutes)) }
    func powerOff() { send(BmapProtocol.powerOff()) }

    func reconnect() {
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        peripheral = nil
        bmapChar = nil
        state = HeadphoneState()
        startScanning()
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            statusMessage = "Scanning..."
            startScanning()
        case .poweredOff:
            statusMessage = "Bluetooth is off"
        case .unauthorized:
            statusMessage = "Bluetooth permission denied"
        default:
            statusMessage = "Bluetooth unavailable"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard isBoseDevice(peripheral, advertisementData: advertisementData) else { return }

        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        statusMessage = "Connecting to \(peripheral.name ?? "device")..."
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        statusMessage = "Discovering services..."
        state.connected = true
        peripheral.discoverServices([Self.bmapServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        state.connected = false
        bmapChar = nil
        statusMessage = "Disconnected"
        reassembler = BmapReassembler()
        // Auto-reconnect
        startScanning()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        statusMessage = "Connection failed"
        startScanning()
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics([Self.secureCharUUID, Self.unsecureCharUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }

        // Prefer secure, fall back to unsecure
        let char = chars.first(where: { $0.uuid == Self.secureCharUUID })
            ?? chars.first(where: { $0.uuid == Self.unsecureCharUUID })
        guard let char else { return }

        bmapChar = char
        peripheral.setNotifyValue(true, for: char)
        statusMessage = nil
        sendInitialQueries()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic === bmapChar, let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        if let reassembled = reassembler.feed(bytes) {
            for packet in BmapPacket.parseMany(reassembled) {
                processPacket(packet)
            }
        }
    }

    // MARK: - Private

    private func startScanning() {
        guard central.state == .poweredOn else { return }
        statusMessage = "Scanning..."

        // Check for already-connected Bose devices first
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.bmapServiceUUID])
        if let first = connected.first {
            self.peripheral = first
            first.delegate = self
            statusMessage = "Connecting to \(first.name ?? "device")..."
            central.connect(first)
            return
        }

        // Scan without UUID filter to find paired devices that may not advertise the service UUID
        central.scanForPeripherals(withServices: nil)
    }

    private func isBoseDevice(_ peripheral: CBPeripheral, advertisementData: [String: Any]) -> Bool {
        let name = peripheral.name ?? ""
        let byName = Self.boseNamePatterns.contains { name.lowercased().contains($0) }
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let byUUID = services.contains(Self.bmapServiceUUID)
        return byName || byUUID
    }

    private func send(_ packet: BmapPacket) {
        guard let char = bmapChar, let peripheral else { return }
        for seg in bmapSegment(packet.toBytes()) {
            peripheral.writeValue(Data(seg), for: char, type: .withoutResponse)
        }
    }

    private func sendInitialQueries() {
        var queries: [BmapPacket] = [
            BmapProtocol.queryName(),
            BmapProtocol.queryBattery(),
            BmapProtocol.queryCnc(),
            BmapProtocol.queryCurrentMode(),
            BmapProtocol.queryStandbyTimer(),
        ]
        // Discover audio modes by probing indices 0..9 (device returns Error for invalid ones)
        for i: UInt8 in 0..<10 {
            queries.append(BmapProtocol.queryModeConfig(i))
        }
        // Stagger writes to avoid overwhelming the BLE stack
        for (i, query) in queries.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.1) { [weak self] in
                self?.send(query)
            }
        }
    }

    private func processPacket(_ packet: BmapPacket) {
        guard packet.op.isResponse, packet.op != .error else { return }

        switch (packet.functionBlock, packet.function) {
        case (.status, FnId.Status.batteryLevel):
            if let info = BmapProtocol.parseBattery(packet) { state.battery = info }

        case (.settings, FnId.Settings.cnc):
            if let cnc = BmapProtocol.parseCnc(packet) { state.cnc = cnc }

        case (.settings, FnId.Settings.productName):
            if let name = BmapProtocol.parseName(packet) { state.productName = name }

        case (.settings, FnId.Settings.standbyTimer):
            if let m = BmapProtocol.parseStandbyTimer(packet) { state.standbyTimerMinutes = m }

        case (.audioModes, FnId.AudioModes.currentMode):
            if let idx = BmapProtocol.parseCurrentMode(packet) { state.audioModeIndex = idx }

        case (.audioModes, FnId.AudioModes.modeConfig):
            if let info = BmapProtocol.parseModeConfig(packet) {
                if let i = state.audioModes.firstIndex(where: { $0.modeIndex == info.modeIndex }) {
                    state.audioModes[i] = info
                } else {
                    state.audioModes.append(info)
                    state.audioModes.sort { $0.modeIndex < $1.modeIndex }
                }
            }
        default:
            break
        }
    }
}
