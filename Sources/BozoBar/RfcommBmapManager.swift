import Foundation
import IOBluetooth
import os

private let rfcommLog = Logger(subsystem: "dev.bozo.bar", category: "RFCOMM")

final class RfcommBmapManager: NSObject, IOBluetoothRFCOMMChannelDelegate {
    var onPacket: ((BmapPacket) -> Void)?
    var onStatus: ((String?) -> Void)?
    var onConnected: ((String) -> Void)?
    var onDisconnected: (() -> Void)?

    private let queue = DispatchQueue(label: "dev.bozo.bar.rfcomm")
    private var channel: IOBluetoothRFCOMMChannel?
    private var receiveBuffer: [UInt8] = []
    private(set) var isConnected = false
    private var isConnecting = false
    private var pendingDisplayName: String?
    private var initialQueriesSent = false
    private let modeConfigIndices: [UInt8] = [0, 1, 2, 3]

    func connect() {
        guard !isConnected, !isConnecting else { return }
        isConnecting = true
        onStatus?("Trying classic Bluetooth control...")

        queue.async { [weak self] in
            self?.connectOnQueue()
        }
    }

    func disconnect() {
        isConnected = false
        isConnecting = false
        queue.async { [weak self] in
            guard let self else { return }
            self.channel?.close()
            self.channel = nil
            self.receiveBuffer.removeAll()
            self.initialQueriesSent = false
        }
    }

    func send(_ packet: BmapPacket) {
        queue.async { [weak self] in
            self?.sendOnQueue(packet)
        }
    }

    private func connectOnQueue() {
        guard let device = findPairedBoseDevice() else {
            DispatchQueue.main.async { [weak self] in
                self?.isConnecting = false
                self?.onStatus?("No paired Bose classic device found")
            }
            return
        }

        let displayName = device.nameOrAddress ?? device.addressString ?? "Bose Headphones"
        rfcommLog.info("classic candidate: \(displayName, privacy: .public) \(device.addressString ?? "", privacy: .public)")

        for channelID in controlChannels(for: device) {
            var openedChannel: IOBluetoothRFCOMMChannel?
            rfcommLog.info("opening RFCOMM channel \(channelID, privacy: .public)")
            let result = device.openRFCOMMChannelSync(&openedChannel, withChannelID: channelID, delegate: self)
            guard let openedChannel else {
                rfcommLog.warning("RFCOMM channel \(channelID, privacy: .public) failed: 0x\(String(format: "%X", result), privacy: .public)")
                continue
            }

            channel = openedChannel
            pendingDisplayName = displayName
            receiveBuffer.removeAll()
            rfcommLog.info("RFCOMM channel \(channelID, privacy: .public) returned 0x\(String(format: "%X", result), privacy: .public)")

            if result == kIOReturnSuccess || openedChannel.isOpen() {
                markConnected(displayName: displayName)
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.isConnecting = false
            self?.onStatus?("Classic Bluetooth control unavailable")
        }
    }

    private func findPairedBoseDevice() -> IOBluetoothDevice? {
        let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        let boseDevices = devices.filter { device in
            let name = (device.nameOrAddress ?? device.addressString ?? "").lowercased()
            return name.contains("bose") || name.contains("quietcomfort")
        }
        return boseDevices.first(where: { $0.isConnected() }) ?? boseDevices.first
    }

    private func controlChannels(for device: IOBluetoothDevice) -> [BluetoothRFCOMMChannelID] {
        var channels: [BluetoothRFCOMMChannelID] = []
        if let channel = sppControlRfcommChannel(for: device) {
            channels.append(channel)
            rfcommLog.info("SDP SPP control RFCOMM channel: \(channel, privacy: .public)")
        }

        for knownControlChannel in [BluetoothRFCOMMChannelID(9), BluetoothRFCOMMChannelID(2), BluetoothRFCOMMChannelID(8)] {
            if !channels.contains(knownControlChannel) {
                channels.append(knownControlChannel)
            }
        }
        return channels
    }

    private func sppControlRfcommChannel(for device: IOBluetoothDevice) -> BluetoothRFCOMMChannelID? {
        let services = device.services as? [IOBluetoothSDPServiceRecord] ?? []
        for service in services {
            let description = String(describing: service).lowercased()
            guard description.contains("spp dev") else { continue }

            var channel = BluetoothRFCOMMChannelID(0)
            let result = service.getRFCOMMChannelID(&channel)
            guard result == kIOReturnSuccess, channel != 0 else { continue }
            return channel
        }
        return nil
    }

    private func sendInitialQueries() {
        guard !initialQueriesSent else { return }
        initialQueriesSent = true

        let queries: [BmapPacket] = [
            BmapPacket(.productInfo, 0x01, .get),
            BmapProtocol.queryName(),
            BmapProtocol.queryBattery(),
            BmapProtocol.queryCnc(),
            BmapProtocol.queryCurrentMode(),
            BmapProtocol.queryStandbyTimer(),
        ] + modeConfigIndices.map(BmapProtocol.queryModeConfig)

        for (index, query) in queries.enumerated() {
            queue.asyncAfter(deadline: .now() + Double(index) * 0.25) { [weak self] in
                self?.sendOnQueue(query)
            }
        }
    }

    private func sendOnQueue(_ packet: BmapPacket) {
        guard let channel, channel.isOpen() else { return }
        var bytes = packet.toBytes()
        let length = UInt16(bytes.count)
        rfcommLog.debug("send fblock=0x\(String(format: "%02X", packet.functionBlock.rawValue), privacy: .public) func=0x\(String(format: "%02X", packet.function), privacy: .public) op=\(packet.op.rawValue, privacy: .public) len=\(packet.payload.count, privacy: .public)")

        let result = bytes.withUnsafeMutableBytes { rawBuffer -> IOReturn in
            guard let baseAddress = rawBuffer.baseAddress else { return kIOReturnBadArgument }
            return channel.writeSync(baseAddress, length: length)
        }

        if result != kIOReturnSuccess {
            rfcommLog.warning("write failed: 0x\(String(format: "%X", result), privacy: .public)")
        }
    }

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard let dataPointer, dataLength > 0 else { return }
        let bytes = Array(UnsafeBufferPointer(start: dataPointer.assumingMemoryBound(to: UInt8.self), count: dataLength))

        queue.async { [weak self] in
            self?.receiveBuffer.append(contentsOf: bytes)
            self?.drainReceiveBuffer()
        }
    }

    private func drainReceiveBuffer() {
        while receiveBuffer.count >= 4 {
            let payloadLength = Int(receiveBuffer[3])
            let packetLength = 4 + payloadLength
            guard receiveBuffer.count >= packetLength else { return }

            let packetBytes = Array(receiveBuffer.prefix(packetLength))
            receiveBuffer.removeFirst(packetLength)

            guard let packet = BmapPacket.fromBytes(packetBytes) else {
                rfcommLog.warning("failed to parse packet: \(packetBytes.map { String(format: "%02X", $0) }.joined(), privacy: .public)")
                continue
            }

            rfcommLog.debug("recv fblock=0x\(String(format: "%02X", packet.functionBlock.rawValue), privacy: .public) func=0x\(String(format: "%02X", packet.function), privacy: .public) op=\(packet.op.rawValue, privacy: .public) len=\(packet.payload.count, privacy: .public)")
            DispatchQueue.main.async { [weak self] in
                self?.onPacket?(packet)
            }
        }
    }

    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        let channelID = rfcommChannel?.getID() ?? 0
        rfcommLog.info("open complete channel \(channelID, privacy: .public): 0x\(String(format: "%X", error), privacy: .public)")
        queue.async { [weak self] in
            guard let self else { return }
            guard error == kIOReturnSuccess else {
                self.isConnecting = false
                self.channel = nil
                DispatchQueue.main.async { [weak self] in
                    self?.onStatus?("Classic Bluetooth control unavailable")
                }
                return
            }

            self.channel = rfcommChannel
            self.markConnected(displayName: self.pendingDisplayName ?? rfcommChannel.getDevice()?.nameOrAddress ?? "Bose Headphones")
        }
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        queue.async { [weak self] in
            guard let self else { return }
            self.channel = nil
            self.receiveBuffer.removeAll()
            self.isConnected = false
            self.isConnecting = false
            self.initialQueriesSent = false
            DispatchQueue.main.async { [weak self] in
                self?.onDisconnected?()
            }
        }
    }

    private func markConnected(displayName: String) {
        guard !isConnected else { return }
        isConnecting = false
        isConnected = true
        rfcommLog.info("RFCOMM connected on channel \(self.channel?.getID() ?? 0, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onConnected?(displayName)
            self.onStatus?("Loading device state...")
        }
        sendInitialQueries()
    }
}
