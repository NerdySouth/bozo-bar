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

struct HeadphoneState {
    var connected: Bool = false
    var productName: String? = nil
    var battery: [BatteryInfo] = []
    var cnc: CncState? = nil
    var audioModeIndex: UInt8? = nil
    var audioModes: [AudioModeInfo] = []
    var standbyTimerMinutes: UInt8? = nil
}
