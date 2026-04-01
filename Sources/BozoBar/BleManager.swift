import CoreBluetooth
import Combine
import os

private let log = Logger(subsystem: "dev.bozo.bar", category: "BLE")

/// A BMAP device discovered during scanning.
struct DiscoveredDevice: Identifiable, Hashable {
    let id: UUID // CBPeripheral identifier
    let name: String
    let rssi: Int
}

/// Manages the BLE connection to Bose headphones using CoreBluetooth directly.
final class BleManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var state = HeadphoneState()
    @Published var statusMessage: String? = "Initializing Bluetooth..."
    /// Devices found during scanning — shown to user for selection.
    @Published var discoveredDevices: [DiscoveredDevice] = []
    /// Whether we need the user to pick a device.
    @Published var needsDeviceSelection = false

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var bmapChar: CBCharacteristic?
    private var reassembler = BmapReassembler()
    private var isScanning = false

    static let bmapServiceUUID = CBUUID(string: "FEBE")
    private static let secureCharUUID = CBUUID(string: "C65B8F2F-AEE2-4C89-B758-BC4892D6F2D8")
    private static let unsecureCharUUID = CBUUID(string: "D417C028-9818-4354-99D1-2AC09D074591")

    private static let savedDeviceKey = "selectedDeviceUUID"

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Public API

    func setAudioMode(_ index: UInt8) { send(BmapProtocol.setCurrentMode(index)) }
    func setStandbyTimer(_ minutes: UInt8) { send(BmapProtocol.setStandbyTimer(minutes)) }
    func setSpatialAudio(_ mode: SpatialAudioMode) { send(BmapProtocol.setSpatialAudio(mode.rawValue)) }
    func powerOff() { send(BmapProtocol.powerOff()) }

    func reconnect() {
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        peripheral = nil
        bmapChar = nil
        state = HeadphoneState()
        startConnection()
    }

    /// User selected a device from the picker.
    func selectDevice(_ device: DiscoveredDevice) {
        UserDefaults.standard.set(device.id.uuidString, forKey: Self.savedDeviceKey)
        log.info("user selected device: \"\(device.name)\" (\(device.id))")
        needsDeviceSelection = false
        central.stopScan()
        isScanning = false
        connectToSavedDevice()
    }

    /// Forget saved device and show picker again.
    func forgetDevice() {
        UserDefaults.standard.removeObject(forKey: Self.savedDeviceKey)
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        peripheral = nil
        bmapChar = nil
        state = HeadphoneState()
        discoveredDevices = []
        needsDeviceSelection = true
        startScan()
    }

    var savedDeviceName: String? {
        guard let uuid = savedDeviceUUID else { return nil }
        let peripherals = central?.retrievePeripherals(withIdentifiers: [uuid])
        return peripherals?.first?.name
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log.info("central state: \(String(describing: central.state.rawValue))")
        switch central.state {
        case .poweredOn:
            startConnection()
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
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? peripheral.name ?? "Unknown Device"

        let device = DiscoveredDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue)

        // Update or add to discovered list
        if let i = discoveredDevices.firstIndex(where: { $0.id == device.id }) {
            discoveredDevices[i] = device
        } else {
            log.info("discovered BMAP device: \"\(name)\" rssi=\(RSSI)")
            discoveredDevices.append(device)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log.info("connected to \(peripheral.name ?? "unknown")")
        statusMessage = "Discovering services..."
        state.connected = true
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log.info("disconnected: \(error?.localizedDescription ?? "clean")")
        state.connected = false
        bmapChar = nil
        statusMessage = "Disconnected"
        reassembler = BmapReassembler()
        // Auto-reconnect if we have a saved device
        if savedDeviceUUID != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.startConnection()
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log.error("failed to connect: \(error?.localizedDescription ?? "unknown")")
        statusMessage = "Connection failed"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.startConnection()
        }
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        log.info("discovered \(services.count) service(s): \(services.map { $0.uuid.uuidString })")
        for service in services where service.uuid == Self.bmapServiceUUID {
            peripheral.discoverCharacteristics([Self.secureCharUUID, Self.unsecureCharUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        let char = chars.first(where: { $0.uuid == Self.secureCharUUID })
            ?? chars.first(where: { $0.uuid == Self.unsecureCharUUID })
        guard let char else { return }

        log.info("using characteristic: \(char.uuid)")
        bmapChar = char
        peripheral.setNotifyValue(true, for: char)
        statusMessage = nil
        sendInitialQueries()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic === bmapChar, let data = characteristic.value else { return }
        if let reassembled = reassembler.feed([UInt8](data)) {
            for packet in BmapPacket.parseMany(reassembled) {
                processPacket(packet)
            }
        }
    }

    // MARK: - Connection Logic

    private var savedDeviceUUID: UUID? {
        guard let str = UserDefaults.standard.string(forKey: Self.savedDeviceKey) else { return nil }
        return UUID(uuidString: str)
    }

    private func startConnection() {
        guard central.state == .poweredOn else { return }

        if savedDeviceUUID != nil {
            connectToSavedDevice()
        } else {
            // No saved device — need user to pick one
            needsDeviceSelection = true
            statusMessage = "Select your headphones"
            startScan()
        }
    }

    private func connectToSavedDevice() {
        guard let uuid = savedDeviceUUID else { return }

        // retrievePeripherals works even if the device isn't advertising — it uses
        // the system's cached peripheral record from previous connections.
        let known = central.retrievePeripherals(withIdentifiers: [uuid])
        if let p = known.first {
            log.info("connecting to saved device: \"\(p.name ?? "")\" (\(uuid))")
            self.peripheral = p
            p.delegate = self
            statusMessage = "Connecting to \(p.name ?? "device")..."
            central.connect(p)
            return
        }

        // Device not found in cache — scan for it
        log.info("saved device not in cache, scanning...")
        statusMessage = "Scanning..."
        startScan()
    }

    private func startScan() {
        guard !isScanning else { return }
        isScanning = true
        discoveredDevices = []
        central.scanForPeripherals(withServices: [Self.bmapServiceUUID], options: nil)
    }

    // MARK: - Packet I/O

    private func send(_ packet: BmapPacket) {
        guard let char = bmapChar, let peripheral else { return }
        for seg in bmapSegment(packet.toBytes()) {
            peripheral.writeValue(Data(seg), for: char, type: .withoutResponse)
        }
    }

    private func sendInitialQueries() {
        let queries: [BmapPacket] = [
            BmapProtocol.queryName(),
            BmapProtocol.queryBattery(),
            BmapProtocol.queryCnc(),
            BmapProtocol.queryCurrentMode(),
            BmapProtocol.queryStandbyTimer(),
            BmapProtocol.querySpatialAudio(),
            BmapProtocol.queryAllModes(),
        ]
        for (i, query) in queries.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.15) { [weak self] in
                self?.send(query)
            }
        }
        let probeStart = Double(queries.count) * 0.15 + 0.5
        for i: UInt8 in 0..<20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + probeStart + Double(i) * 0.15) { [weak self] in
                self?.send(BmapProtocol.queryModeConfig(i))
            }
        }
    }

    private func queryModeConfigs(indices: [UInt8]) {
        for (i, idx) in indices.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.15) { [weak self] in
                self?.send(BmapProtocol.queryModeConfig(idx))
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
        case (.audioModes, FnId.AudioModes.getAll):
            if let indices = BmapProtocol.parseAllModes(packet) { queryModeConfigs(indices: indices) }
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
        case (.audioManagement, FnId.AudioManagement.spatialAudioMode):
            if let raw = BmapProtocol.parseSpatialAudio(packet),
               let mode = SpatialAudioMode(rawValue: raw) {
                state.spatialAudio = mode
            }
        default:
            break
        }
    }
}
