import Foundation

struct BatteryInfo: Identifiable {
    let percentage: UInt8
    let remainingMinutes: UInt16?
    let componentId: UInt8
    var id: UInt8 { componentId }
}

struct CncState {
    let currentStep: UInt8
    let totalSteps: UInt8
    let enabled: Bool
    let userEnableDisable: Bool
}

struct AudioModeInfo: Identifiable {
    let modeIndex: UInt8
    let name: String
    var id: UInt8 { modeIndex }
}

/// Spatial audio mode: 0=off, 1=still (fixed to room), 2=motion (fixed to head).
enum SpatialAudioMode: UInt8, CaseIterable, Identifiable {
    case off = 0
    case still = 1
    case motion = 2

    var id: UInt8 { rawValue }

    var label: String {
        switch self {
        case .off: "Off"
        case .still: "Still"
        case .motion: "Motion"
        }
    }
}

struct HeadphoneState {
    var connected: Bool = false
    var productName: String? = nil
    var battery: [BatteryInfo] = []
    var cnc: CncState? = nil
    var audioModeIndex: UInt8? = nil
    var audioModes: [AudioModeInfo] = []
    var standbyTimerMinutes: UInt8? = nil
    var spatialAudio: SpatialAudioMode? = nil
}
