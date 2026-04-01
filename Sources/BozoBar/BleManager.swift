import CoreBluetooth
import Combine
import os

private let log = Logger(subsystem: "dev.bozo.bar", category: "BLE")

/// Manages the BLE connection to Bose headphones using CoreBluetooth directly.
final class BleManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var state = HeadphoneState()
    @Published var statusMessage: String? = "Initializing Bluetooth..."

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var bmapChar: CBCharacteristic?
    private var reassembler = BmapReassembler()

    // UUIDs matching the Rust daemon
    private static let bmapServiceUUID = CBUUID(string: "FEBE")
    private static let secureCharUUID = CBUUID(string: "C65B8F2F-AEE2-4C89-B758-BC4892D6F2D8")
    private static let unsecureCharUUID = CBUUID(string: "D417C028-9818-4354-99D1-2AC09D074591")

    private static let boseNamePatterns = ["bose", "adjuster"]

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
        startScanning()
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log.info("central state: \(String(describing: central.state.rawValue))")
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
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? peripheral.name ?? ""

        guard isBoseDevice(name: name, advertisementData: advertisementData) else { return }

        log.info("found Bose device: \"\(name)\" rssi=\(RSSI)")
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        statusMessage = "Connecting to \(name)..."
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log.info("connected to \(peripheral.name ?? "unknown")")
        statusMessage = "Discovering services..."
        state.connected = true
        // Discover ALL services first, then look for BMAP among them
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log.info("disconnected: \(error?.localizedDescription ?? "clean")")
        state.connected = false
        bmapChar = nil
        statusMessage = "Disconnected"
        reassembler = BmapReassembler()
        startScanning()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log.error("failed to connect: \(error?.localizedDescription ?? "unknown")")
        statusMessage = "Connection failed"
        startScanning()
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else {
            log.error("no services discovered: \(error?.localizedDescription ?? "nil")")
            return
        }
        log.info("discovered \(services.count) service(s): \(services.map { $0.uuid.uuidString })")
        for service in services {
            if service.uuid == Self.bmapServiceUUID {
                peripheral.discoverCharacteristics([Self.secureCharUUID, Self.unsecureCharUUID], for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        log.info("characteristics for \(service.uuid): \(chars.map { $0.uuid.uuidString })")

        let char = chars.first(where: { $0.uuid == Self.secureCharUUID })
            ?? chars.first(where: { $0.uuid == Self.unsecureCharUUID })
        guard let char else {
            log.warning("BMAP characteristic not found in service")
            return
        }

        log.info("using characteristic: \(char.uuid)")
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

        // Check for Bose devices already connected via BLE
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.bmapServiceUUID])
        log.info("retrieveConnectedPeripherals returned \(connected.count) device(s)")
        for p in connected {
            let name = p.name ?? ""
            if isBoseDevice(name: name, advertisementData: [:]) {
                log.info("found already-connected Bose device: \"\(name)\"")
                self.peripheral = p
                p.delegate = self
                statusMessage = "Connecting to \(name)..."
                central.connect(p)
                return
            }
        }

        // Scan for advertising devices — no service filter so we catch everything
        log.info("starting BLE scan...")
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false,
        ])
    }

    private func isBoseDevice(name: String, advertisementData: [String: Any]) -> Bool {
        let lower = name.lowercased()
        let byName = !lower.isEmpty && Self.boseNamePatterns.contains { lower.contains($0) }
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let overflow = advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
        let byUUID = (services + overflow).contains(Self.bmapServiceUUID)
        return byName || byUUID
    }

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
        // Fallback: brute-force probe indices 0..19 in case GET_ALL doesn't work
        let probeStart = Double(queries.count) * 0.15 + 0.5
        for i: UInt8 in 0..<20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + probeStart + Double(i) * 0.15) { [weak self] in
                self?.send(BmapProtocol.queryModeConfig(i))
            }
        }
    }

    /// After receiving the mode index list, query each mode's config for its name.
    private func queryModeConfigs(indices: [UInt8]) {
        log.info("querying config for \(indices.count) mode(s): \(indices)")
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
            log.info("GET_ALL response op=\(packet.op.rawValue) payload(\(packet.payload.count))=\(packet.payload.map { String(format: "%02x", $0) }.joined(separator: " "))")
            if let indices = BmapProtocol.parseAllModes(packet) {
                queryModeConfigs(indices: indices)
            }

        case (.audioModes, FnId.AudioModes.currentMode):
            if let idx = BmapProtocol.parseCurrentMode(packet) { state.audioModeIndex = idx }

        case (.audioModes, FnId.AudioModes.modeConfig):
            log.info("MODE_CONFIG response idx=\(packet.payload.first ?? 0) payload(\(packet.payload.count))=\(packet.payload.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " "))")
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
                log.info("spatial audio: \(mode.label)")
                state.spatialAudio = mode
            }

        default:
            if packet.functionBlock == .audioModes {
                log.info("unhandled audioModes func=0x\(String(format: "%02x", packet.function)) op=\(packet.op.rawValue) payload(\(packet.payload.count))=\(packet.payload.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " "))")
            }
        }
    }
}
