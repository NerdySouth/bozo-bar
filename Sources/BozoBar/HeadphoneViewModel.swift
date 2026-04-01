import SwiftUI
import Combine

@MainActor
final class HeadphoneViewModel: ObservableObject {
    @Published var state = HeadphoneState()
    @Published var statusMessage: String? = "Initializing..."
    @Published var discoveredDevices: [DiscoveredDevice] = []
    @Published var needsDeviceSelection = false

    let ble = BleManager()
    private var cancellables = Set<AnyCancellable>()

    init() {
        ble.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.state = $0 }
            .store(in: &cancellables)

        ble.$statusMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.statusMessage = $0 }
            .store(in: &cancellables)

        ble.$discoveredDevices
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.discoveredDevices = $0 }
            .store(in: &cancellables)

        ble.$needsDeviceSelection
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.needsDeviceSelection = $0 }
            .store(in: &cancellables)
    }

    var menuBarTitle: String {
        if let pct = state.battery.first?.percentage {
            return "\(pct)%"
        }
        return "--"
    }

    var currentModeName: String? {
        guard let idx = state.audioModeIndex else { return nil }
        return state.audioModes.first(where: { $0.modeIndex == idx })?.name
    }

    func selectDevice(_ device: DiscoveredDevice) { ble.selectDevice(device) }
    func setAudioMode(_ index: UInt8) { ble.setAudioMode(index) }
    func setStandbyTimer(_ minutes: UInt8) { ble.setStandbyTimer(minutes) }
    func setSpatialAudio(_ mode: SpatialAudioMode) { ble.setSpatialAudio(mode) }
    func powerOff() { ble.powerOff() }
    func reconnect() { ble.reconnect() }
    func forgetDevice() { ble.forgetDevice() }
}
