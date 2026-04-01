import Foundation

/// Typed BMAP message builders and response parsers, matching the Rust bozo-proto crate.
enum BmapProtocol {

    // MARK: - Battery

    static func queryBattery() -> BmapPacket {
        BmapPacket(.status, FnId.Status.batteryLevel, .get)
    }

    /// Payload: repeating 4-byte chunks [percentage, remaining_hi, remaining_lo, component_id].
    static func parseBattery(_ pkt: BmapPacket) -> [BatteryInfo]? {
        guard pkt.functionBlock == .status, pkt.function == FnId.Status.batteryLevel else { return nil }
        let p = pkt.payload
        if p.isEmpty { return [] }

        var results = [BatteryInfo]()
        if p.count < 4 {
            results.append(BatteryInfo(percentage: p[0], remainingMinutes: nil, componentId: 0))
        } else {
            var off = 0
            while off + 4 <= p.count {
                let raw = (UInt16(p[off + 1]) << 8) | UInt16(p[off + 2])
                let remaining: UInt16? = raw == 0xFFFF ? nil : raw
                results.append(BatteryInfo(percentage: p[off], remainingMinutes: remaining, componentId: p[off + 3]))
                off += 4
            }
        }
        return results
    }

    // MARK: - CNC (Noise Cancellation)

    static func queryCnc() -> BmapPacket {
        BmapPacket(.settings, FnId.Settings.cnc, .get)
    }

    static func setCnc(level: UInt8, enabled: Bool) -> BmapPacket {
        BmapPacket(.settings, FnId.Settings.cnc, .setGet, [level, enabled ? 1 : 0])
    }

    /// Payload: [currentStep, numSteps, flags]. Bit 0 = enabled, bit 1 = userEnableDisable (inverted).
    static func parseCnc(_ pkt: BmapPacket) -> CncState? {
        guard pkt.functionBlock == .settings, pkt.function == FnId.Settings.cnc,
              pkt.payload.count >= 3 else { return nil }
        let p = pkt.payload
        return CncState(
            currentStep: p[0],
            totalSteps: p[1],
            enabled: (p[2] & 1) == 1,
            userEnableDisable: ((p[2] >> 1) & 1) == 0
        )
    }

    // MARK: - Product Name

    static func queryName() -> BmapPacket {
        BmapPacket(.settings, FnId.Settings.productName, .get)
    }

    static func parseName(_ pkt: BmapPacket) -> String? {
        guard pkt.functionBlock == .settings, pkt.function == FnId.Settings.productName else { return nil }
        let trimmed = pkt.payload.filter { $0 != 0 }
        return String(bytes: trimmed, encoding: .utf8)
    }

    // MARK: - Standby Timer

    static func queryStandbyTimer() -> BmapPacket {
        BmapPacket(.settings, FnId.Settings.standbyTimer, .get)
    }

    static func setStandbyTimer(_ minutes: UInt8) -> BmapPacket {
        BmapPacket(.settings, FnId.Settings.standbyTimer, .setGet, [minutes])
    }

    static func parseStandbyTimer(_ pkt: BmapPacket) -> UInt8? {
        guard pkt.functionBlock == .settings, pkt.function == FnId.Settings.standbyTimer else { return nil }
        return pkt.payload.first
    }

    // MARK: - Audio Modes

    /// Query the list of all available mode indices.
    static func queryAllModes() -> BmapPacket {
        BmapPacket(.audioModes, FnId.AudioModes.getAll, .get)
    }

    /// Parse a GetAll response — payload is a list of mode index bytes.
    static func parseAllModes(_ pkt: BmapPacket) -> [UInt8]? {
        guard pkt.functionBlock == .audioModes, pkt.function == FnId.AudioModes.getAll else { return nil }
        return pkt.payload.isEmpty ? nil : Array(pkt.payload)
    }

    static func queryCurrentMode() -> BmapPacket {
        BmapPacket(.audioModes, FnId.AudioModes.currentMode, .get)
    }

    static func queryModeConfig(_ index: UInt8) -> BmapPacket {
        BmapPacket(.audioModes, FnId.AudioModes.modeConfig, .get, [index])
    }

    static func setCurrentMode(_ index: UInt8) -> BmapPacket {
        BmapPacket(.audioModes, FnId.AudioModes.currentMode, .start, [index, 0x00])
    }

    static func parseCurrentMode(_ pkt: BmapPacket) -> UInt8? {
        guard pkt.functionBlock == .audioModes, pkt.function == FnId.AudioModes.currentMode else { return nil }
        return pkt.payload.first
    }

    /// ModeConfig payload (47-48 bytes):
    ///   byte 0:     mode index
    ///   bytes 1-2:  prompt (byte1, byte2) — predefined mode category
    ///   byte 3:     userConfigurable
    ///   byte 4:     userConfigured
    ///   byte 5:     favorite
    ///   bytes 6-37: mode name (null-terminated UTF-8, 32 bytes)
    static func parseModeConfig(_ pkt: BmapPacket) -> AudioModeInfo? {
        guard pkt.functionBlock == .audioModes, pkt.function == FnId.AudioModes.modeConfig,
              pkt.payload.count >= 7 else { return nil }
        let p = pkt.payload
        let index = p[0]
        let promptId = p.count >= 3 ? p[2] : 0

        // Parse text name from bytes 6..37
        let nameEnd = min(p.count, 38)
        let nameBytes = Array(p[6..<nameEnd])
        let nullPos = nameBytes.firstIndex(of: 0) ?? nameBytes.count
        let textName = String(bytes: nameBytes[..<nullPos], encoding: .utf8) ?? ""

        // Use prompt name when text name is empty or "None"
        let promptName = promptNames[promptId]
        let name: String
        if !textName.isEmpty && textName != "None" {
            name = textName
        } else if let promptName {
            name = promptName
        } else {
            // No prompt name and no real text name — skip empty slot
            return nil
        }

        return AudioModeInfo(modeIndex: index, name: name)
    }

    /// Prompt byte2 → display name, from the Bose Music APK AudioModesPrompt enum.
    private static let promptNames: [UInt8: String] = [
        1: "Quiet", 2: "Aware", 3: "Transparent", 4: "Transparency",
        5: "Masking", 6: "Comfort", 7: "Commute", 8: "Outdoor",
        9: "Workout", 10: "Home", 11: "Work", 12: "Music",
        13: "Focus", 14: "Relax", 15: "Flight", 16: "Airport",
        17: "Driving", 18: "Training", 19: "Gym", 20: "Run",
        21: "Walk", 22: "Hike", 23: "Talk", 24: "Call",
        25: "Whisper", 26: "Hearing", 27: "Learn", 28: "Podcast",
        29: "Audiobook", 30: "Calm", 31: "Sleep", 32: "Meditate",
        33: "Yoga", 34: "Immersion", 35: "Stereo", 36: "Cinema",
    ]

    // MARK: - Power

    static func powerOff() -> BmapPacket {
        BmapPacket(.control, FnId.Control.power, .start, [0x00])
    }

    static func powerOn() -> BmapPacket {
        BmapPacket(.control, FnId.Control.power, .start, [0x01])
    }
}
