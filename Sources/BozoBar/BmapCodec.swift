import Foundation

// MARK: - Function Block IDs (byte 0 of BMAP header)

enum FunctionBlock: UInt8 {
    case productInfo = 0x00
    case settings = 0x01
    case status = 0x02
    case firmwareUpdate = 0x03
    case deviceManagement = 0x04
    case audioManagement = 0x05
    case callManagement = 0x06
    case control = 0x07
    case debug = 0x08
    case notification = 0x09
    case hearingAssistance = 0x0C
    case dataCollection = 0x0D
    case heartRate = 0x0E
    case peerBud = 0x0F
    case vpa = 0x10
    case wifi = 0x11
    case authentication = 0x12
    case experimental = 0x13
    case cloud = 0x14
    case augmentedReality = 0x15
    case print = 0x16
    case audioModes = 0x1F
}

// MARK: - Operator (low 4 bits of byte 2)

enum BmapOp: UInt8 {
    case set = 0
    case get = 1
    case setGet = 2
    case status = 3
    case error = 4
    case start = 5
    case result = 6
    case processing = 7

    var isResponse: Bool {
        switch self {
        case .status, .error, .result, .processing: true
        default: false
        }
    }
}

// MARK: - Function IDs per block

enum FnId {
    enum Settings {
        static let productName: UInt8 = 0x02
        static let standbyTimer: UInt8 = 0x04
        static let cnc: UInt8 = 0x05
    }
    enum Status {
        static let batteryLevel: UInt8 = 0x02
    }
    enum Control {
        static let power: UInt8 = 0x04
    }
    enum AudioModes {
        static let getAll: UInt8 = 0x01
        static let currentMode: UInt8 = 0x03
        static let modeConfig: UInt8 = 0x06
    }
}

// MARK: - BMAP Packet

struct BmapPacket {
    var functionBlock: FunctionBlock
    var function: UInt8
    var deviceId: UInt8 = 0
    var port: UInt8 = 0
    var op: BmapOp
    var payload: [UInt8]

    init(_ fb: FunctionBlock, _ function: UInt8, _ op: BmapOp, _ payload: [UInt8] = []) {
        self.functionBlock = fb
        self.function = function
        self.op = op
        self.payload = payload
    }

    func toBytes() -> [UInt8] {
        var buf = [UInt8]()
        buf.reserveCapacity(4 + payload.count)
        buf.append(functionBlock.rawValue)
        buf.append(function)
        buf.append((deviceId << 6) | (port << 4) | (op.rawValue & 0x0F))
        buf.append(UInt8(payload.count))
        buf.append(contentsOf: payload)
        return buf
    }

    static func fromBytes(_ data: [UInt8]) -> BmapPacket? {
        guard data.count >= 4 else { return nil }
        guard let fb = FunctionBlock(rawValue: data[0]) else { return nil }
        let byte2 = data[2]
        guard let op = BmapOp(rawValue: byte2 & 0x0F) else { return nil }
        let payloadLen = Int(data[3])
        guard data.count >= 4 + payloadLen else { return nil }

        var pkt = BmapPacket(fb, data[1], op, Array(data[4..<(4 + payloadLen)]))
        pkt.deviceId = byte2 >> 6
        pkt.port = (byte2 >> 4) & 0x03
        return pkt
    }

    static func parseMany(_ data: [UInt8]) -> [BmapPacket] {
        var results = [BmapPacket]()
        var offset = 0
        while offset + 4 <= data.count {
            let payloadLen = Int(data[offset + 3])
            let packetLen = 4 + payloadLen
            guard offset + packetLen <= data.count else { break }
            if let pkt = fromBytes(Array(data[offset..<(offset + packetLen)])) {
                results.append(pkt)
            }
            offset += packetLen
        }
        return results
    }
}

// MARK: - BLE Segmentation

private let segmentDataSize = 19

func bmapSegment(_ data: [UInt8]) -> [[UInt8]] {
    if data.isEmpty { return [[0x00]] }

    let fullSegs = data.count / segmentDataSize
    let remainder = data.count % segmentDataSize
    let total = fullSegs + (remainder > 0 ? 1 : 0)
    let maxIdx = UInt8(total - 1)

    var segments = [[UInt8]]()
    segments.reserveCapacity(total)
    var offset = 0

    for i in 0..<total {
        let chunkSize = i < fullSegs ? segmentDataSize : remainder
        var seg = [UInt8]()
        seg.reserveCapacity(1 + chunkSize)
        seg.append((maxIdx << 4) | UInt8(i))
        seg.append(contentsOf: data[offset..<(offset + chunkSize)])
        segments.append(seg)
        offset += chunkSize
    }

    return segments
}

// MARK: - Reassembler

final class BmapReassembler {
    private var segments: [[UInt8]?] = []
    private var expectedCount: Int?

    func feed(_ segment: [UInt8]) -> [UInt8]? {
        guard !segment.isEmpty else { return nil }

        let header = segment[0]

        // Single unsegmented packet
        if header == 0x00 {
            reset()
            return Array(segment.dropFirst())
        }

        let maxIndex = Int((header >> 4) & 0x0F)
        let currentIndex = Int(header & 0x0F)
        let count = maxIndex + 1

        if let prev = expectedCount, prev != count { reset(); return nil }
        guard currentIndex <= maxIndex else { reset(); return nil }

        expectedCount = count
        if segments.isEmpty { segments = Array(repeating: nil, count: count) }
        segments[currentIndex] = Array(segment.dropFirst())

        // Complete when last segment received and all slots filled
        let isLast = maxIndex == currentIndex
        if isLast && segments.allSatisfy({ $0 != nil }) {
            let data = segments.compactMap { $0 }.flatMap { $0 }
            reset()
            return data
        }
        return nil
    }

    private func reset() {
        segments.removeAll()
        expectedCount = nil
    }
}
