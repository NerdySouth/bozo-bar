import CoreBluetooth
import Combine
import os

private let log = Logger(subsystem: "dev.bozo.bar", category: "BLE")
private let bmapLog = Logger(subsystem: "dev.bozo.bar", category: "BMAP")

private enum TransportPreference {
    case ble
    case classic
}

/// A BMAP device discovered during scanning.
struct DiscoveredDevice: Identifiable, Hashable {
    let id: UUID // CBPeripheral identifier
    let name: String
    let rssi: Int
}

/// Coordinates BMAP control over BLE and classic Bluetooth.
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
    private var bmapCharacteristics: [CBCharacteristic] = []
    private var initialQueriesSent = false
    private var reassembler = BmapReassembler()
    private var isScanning = false
    private var isConnecting = false
    private var connectionAttemptID: UUID?
    private let rfcomm = RfcommBmapManager()
    private var activeTransport: TransportPreference = .ble
    private var bleResponseCount = 0
    private var classicRetryScheduled = false

    private var usingClassicTransport: Bool { activeTransport == .classic }

    static let bmapServiceUUID = CBUUID(string: "FEBE")
    private static let secureCharUUID = CBUUID(string: "C65B8F2F-AEE2-4C89-B758-BC4892D6F2D8")
    private static let unsecureCharUUID = CBUUID(string: "D417C028-9818-4354-99D1-2AC09D074591")

    private static let savedDeviceKey = "selectedDeviceUUID"
    private static let preferredTransportKey = "preferredTransport"

    override init() {
        super.init()
        rfcomm.onPacket = { [weak self] packet in
            self?.processPacket(packet)
        }
        rfcomm.onStatus = { [weak self] message in
            self?.statusMessage = message
        }
        rfcomm.onConnected = { [weak self] name in
            guard let self else { return }
            self.preferredTransport = .classic
            self.activeTransport = .classic
            self.state.connected = true
            self.state.productName = self.state.productName ?? name
            self.needsDeviceSelection = false
        }
        rfcomm.onDisconnected = { [weak self] in
            guard let self else { return }
            self.state.connected = false
            self.statusMessage = "Classic Bluetooth disconnected"
        }
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Public API

    func setAudioMode(_ index: UInt8) {
        guard state.connected else { return }
        state.audioModeIndex = index
        sendControl(BmapProtocol.setCurrentMode(index))
        refreshAfterControl(BmapProtocol.queryCurrentMode())
    }

    func setCnc(level: UInt8, enabled: Bool) {
        guard state.connected else { return }
        if let cnc = state.cnc {
            state.cnc = CncState(
                currentStep: level,
                totalSteps: cnc.totalSteps,
                enabled: enabled,
                userEnableDisable: cnc.userEnableDisable
            )
        }
        sendControl(BmapProtocol.setCnc(level: level, enabled: enabled))
        refreshAfterControl(BmapProtocol.queryCnc())
    }

    func setStandbyTimer(_ minutes: UInt8) {
        guard state.connected else { return }
        state.standbyTimerMinutes = minutes
        sendControl(BmapProtocol.setStandbyTimer(minutes))
        refreshAfterControl(BmapProtocol.queryStandbyTimer())
    }

    func setSpatialAudio(_ mode: SpatialAudioMode) {
        guard state.connected else { return }
        state.spatialAudio = mode
        sendControl(BmapProtocol.setSpatialAudio(mode.rawValue))
        refreshAfterControl(BmapProtocol.querySpatialAudio())
    }
    func powerOff() { sendControl(BmapProtocol.powerOff()) }

    func reconnect() {
        rfcomm.disconnect()
        stopScan()
        resetBleConnection(cancelPeripheral: true)
        state = HeadphoneState()
        startConnection()
    }

    /// User selected a device from the picker.
    func selectDevice(_ device: DiscoveredDevice) {
        UserDefaults.standard.set(device.id.uuidString, forKey: Self.savedDeviceKey)
        preferredTransport = nil
        activeTransport = .ble
        log.info("user selected device: \"\(device.name)\" (\(device.id))")
        needsDeviceSelection = false
        stopScan()
        connectToSavedDevice()
    }

    /// Forget saved device and show picker again.
    func forgetDevice() {
        UserDefaults.standard.removeObject(forKey: Self.savedDeviceKey)
        preferredTransport = nil
        activeTransport = .ble
        rfcomm.disconnect()
        stopScan()
        resetBleConnection(cancelPeripheral: true)
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

        if peripheral.identifier == savedDeviceUUID, self.peripheral == nil, !isConnecting {
            log.info("found saved device while scanning; connecting")
            stopScan()
            connect(peripheral, displayName: name)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnecting = false
        connectionAttemptID = nil
        log.info("connected to \(peripheral.name ?? "unknown")")
        statusMessage = "Discovering services..."
        state.connected = true
        peripheral.discoverServices([Self.bmapServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        isConnecting = false
        connectionAttemptID = nil
        log.info("disconnected: \(error?.localizedDescription ?? "clean")")
        if !usingClassicTransport {
            state.connected = false
        }
        bmapChar = nil
        bmapCharacteristics = []
        initialQueriesSent = false
        if !usingClassicTransport {
            statusMessage = "Disconnected"
        }
        reassembler = BmapReassembler()
        if savedDeviceUUID != nil, !usingClassicTransport {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.startConnection()
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        isConnecting = false
        connectionAttemptID = nil
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
        for char in chars {
            log.info("discovered characteristic: \(char.uuid.uuidString, privacy: .public) props=0x\(String(format: "%X", char.properties.rawValue), privacy: .public)")
        }

        bmapCharacteristics = chars.filter {
            $0.uuid == Self.secureCharUUID || $0.uuid == Self.unsecureCharUUID
        }

        let char = bmapCharacteristics.first(where: { $0.uuid == Self.secureCharUUID })
            ?? bmapCharacteristics.first(where: { $0.uuid == Self.unsecureCharUUID })
        guard let char else { return }

        log.info("using write characteristic: \(char.uuid.uuidString, privacy: .public)")
        bmapChar = char
        statusMessage = "Starting notifications..."

        for notifyChar in bmapCharacteristics where notifyChar.properties.contains(.notify) || notifyChar.properties.contains(.indicate) {
            peripheral.setNotifyValue(true, for: notifyChar)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard bmapCharacteristics.contains(where: { $0 === characteristic }) else { return }

        if let error {
            log.error("failed to start notifications: \(error.localizedDescription)")
            statusMessage = "Notification setup failed"
            return
        }

        guard !initialQueriesSent else { return }

        let notifiable = bmapCharacteristics.filter {
            $0.properties.contains(.notify) || $0.properties.contains(.indicate)
        }
        guard !notifiable.isEmpty, notifiable.allSatisfy(\.isNotifying) else { return }

        initialQueriesSent = true
        log.info("notifications active")
        statusMessage = "Loading device state..."
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.sendInitialQueries()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard bmapCharacteristics.contains(where: { $0 === characteristic }),
              let data = characteristic.value else { return }
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

    private var preferredTransport: TransportPreference? {
        get {
            switch UserDefaults.standard.string(forKey: Self.preferredTransportKey) {
            case "ble":
                return .ble
            case "classic", "rfcomm":
                return .classic
            default:
                return nil
            }
        }
        set {
            switch newValue {
            case .ble:
                UserDefaults.standard.set("ble", forKey: Self.preferredTransportKey)
            case .classic:
                UserDefaults.standard.set("classic", forKey: Self.preferredTransportKey)
            case nil:
                UserDefaults.standard.removeObject(forKey: Self.preferredTransportKey)
            }
        }
    }

    private func startConnection() {
        guard central.state == .poweredOn else { return }
        if savedDeviceUUID != nil, preferredTransport == .classic {
            startClassicControl()
            return
        }

        guard !usingClassicTransport else {
            startClassicControl()
            return
        }

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
        guard !isConnecting, !state.connected else { return }

        let connected = central.retrieveConnectedPeripherals(withServices: [Self.bmapServiceUUID])
        if let p = connected.first(where: { $0.identifier == uuid }) {
            log.info("connecting to currently connected saved device: \"\(p.name ?? "")\" (\(uuid))")
            connect(p, displayName: p.name ?? "device")
            return
        }

        // retrievePeripherals works even if the device isn't advertising — it uses
        // the system's cached peripheral record from previous connections.
        let known = central.retrievePeripherals(withIdentifiers: [uuid])
        if let p = known.first {
            log.info("connecting to saved device: \"\(p.name ?? "")\" (\(uuid))")
            connect(p, displayName: p.name ?? "device")
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

        let connected = central.retrieveConnectedPeripherals(withServices: [Self.bmapServiceUUID])
        for peripheral in connected {
            let name = peripheral.name ?? "Bose Headphones"
            let device = DiscoveredDevice(id: peripheral.identifier, name: name, rssi: 0)
            discoveredDevices.append(device)
            log.info("found connected BMAP device: \"\(name)\"")

            if peripheral.identifier == savedDeviceUUID, self.peripheral == nil, !isConnecting {
                stopScan()
                connect(peripheral, displayName: name)
                return
            }
        }

        central.scanForPeripherals(withServices: [Self.bmapServiceUUID], options: nil)
    }

    private func connect(_ peripheral: CBPeripheral, displayName: String) {
        guard !isConnecting, !state.connected else { return }
        self.peripheral = peripheral
        peripheral.delegate = self
        bmapChar = nil
        bmapCharacteristics = []
        initialQueriesSent = false
        reassembler = BmapReassembler()
        isConnecting = true
        needsDeviceSelection = false
        statusMessage = "Connecting to \(displayName)..."
        let attemptID = UUID()
        connectionAttemptID = attemptID
        central.connect(peripheral)

        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak peripheral] in
            guard let self,
                  !self.usingClassicTransport,
                  self.isConnecting,
                  self.connectionAttemptID == attemptID,
                  let peripheral,
                  self.peripheral?.identifier == peripheral.identifier
            else { return }

            log.warning("connection timed out; scanning for BMAP devices")
            self.connectionAttemptID = nil
            self.isConnecting = false
            self.statusMessage = "Scanning..."
            self.needsDeviceSelection = true
            self.peripheral = nil
            self.central.cancelPeripheralConnection(peripheral)
            self.startScan()
        }
    }

    // MARK: - Packet I/O

    private func send(_ packet: BmapPacket) {
        guard let char = bmapChar, let peripheral else { return }
        let writeType: CBCharacteristicWriteType = char.properties.contains(.writeWithoutResponse)
            ? .withoutResponse
            : .withResponse

        bmapLog.debug("BLE send fblock=0x\(String(format: "%02X", packet.functionBlock.rawValue), privacy: .public) func=0x\(String(format: "%02X", packet.function), privacy: .public) op=\(packet.op.rawValue, privacy: .public) len=\(packet.payload.count, privacy: .public)")
        for seg in bmapSegment(packet.toBytes()) {
            peripheral.writeValue(Data(seg), for: char, type: writeType)
        }
    }

    private func sendControl(_ packet: BmapPacket) {
        if rfcomm.isConnected {
            rfcomm.send(packet)
        } else {
            send(packet)
        }
    }

    private func refreshAfterControl(_ packet: BmapPacket) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.sendControl(packet)
        }
    }

    private func sendInitialQueries() {
        bleResponseCount = 0
        scheduleClassicRetry()

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
    }

    private func queryModeConfigs(indices: [UInt8]) {
        for (i, idx) in indices.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.15) { [weak self] in
                self?.send(BmapProtocol.queryModeConfig(idx))
            }
        }
    }

    private func processPacket(_ packet: BmapPacket) {
        guard packet.op.isResponse else { return }

        if packet.op == .error {
            let errorCode = packet.payload.first.map { String(format: "0x%02X", $0) } ?? "none"
            bmapLog.debug("device error fblock=0x\(String(format: "%02X", packet.functionBlock.rawValue), privacy: .public) func=0x\(String(format: "%02X", packet.function), privacy: .public) code=\(errorCode, privacy: .public)")
            if !usingClassicTransport, bleResponseCount == 0 {
                startClassicControl(reason: "BLE returned BMAP error \(errorCode)")
            }
            return
        }

        bmapLog.debug("recv fblock=0x\(String(format: "%02X", packet.functionBlock.rawValue), privacy: .public) func=0x\(String(format: "%02X", packet.function), privacy: .public) op=\(packet.op.rawValue, privacy: .public) len=\(packet.payload.count, privacy: .public)")
        if !usingClassicTransport {
            bleResponseCount += 1
            preferredTransport = .ble
        }

        switch (packet.functionBlock, packet.function) {
        case (.status, FnId.Status.batteryLevel):
            if let info = BmapProtocol.parseBattery(packet) {
                state.battery = info
                statusMessage = nil
            }
        case (.settings, FnId.Settings.cnc):
            if let cnc = BmapProtocol.parseCnc(packet) {
                state.cnc = cnc
                statusMessage = nil
            }
        case (.settings, FnId.Settings.productName):
            if let name = BmapProtocol.parseName(packet) {
                state.productName = name
                statusMessage = nil
            }
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

    private func scheduleClassicRetry() {
        guard !classicRetryScheduled, !usingClassicTransport else { return }
        classicRetryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self else { return }
            self.classicRetryScheduled = false
            guard !self.usingClassicTransport,
                  self.state.connected,
                  self.bleResponseCount == 0
            else { return }

            self.startClassicControl(reason: "BLE produced no BMAP responses")
        }
    }

    private func startClassicControl(reason: String? = nil) {
        guard !rfcomm.isConnected else { return }
        activeTransport = .classic
        if let reason {
            log.info("using classic Bluetooth control: \(reason, privacy: .public)")
        }
        statusMessage = "Connecting with classic Bluetooth control..."
        stopScan()
        resetBleConnection(cancelPeripheral: true)
        rfcomm.connect()
    }

    private func stopScan() {
        central.stopScan()
        isScanning = false
    }

    private func resetBleConnection(cancelPeripheral: Bool) {
        if cancelPeripheral, let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        connectionAttemptID = nil
        isConnecting = false
        peripheral = nil
        bmapChar = nil
        bmapCharacteristics = []
        initialQueriesSent = false
        reassembler = BmapReassembler()
    }
}
