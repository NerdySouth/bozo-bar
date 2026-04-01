import SwiftUI

struct MenuContent: View {
    @ObservedObject var vm: HeadphoneViewModel

    var body: some View {
        // Header
        Text(vm.state.productName ?? "No Device")
            .font(.headline)

        if vm.state.connected {
            Text("Connected")
        } else {
            Text("Disconnected")
                .foregroundColor(.secondary)
        }

        Divider()

        // Battery
        if let batt = vm.state.battery.first {
            let remaining = batt.remainingMinutes.map { " (\($0) min)" } ?? ""
            Label("Battery: \(batt.percentage)%\(remaining)", systemImage: batteryIcon(batt.percentage))
        } else {
            Label("Battery: --", systemImage: "battery.0percent")
        }

        Divider()

        // Audio mode
        if !vm.state.audioModes.isEmpty {
            Picker("Audio Mode", selection: audioModeBinding) {
                ForEach(vm.state.audioModes) { mode in
                    Text(mode.name).tag(mode.modeIndex)
                }
            }
        }

        // Standby timer
        Picker("Standby Timer", selection: standbyBinding) {
            ForEach(standbyOptions, id: \.self) { minutes in
                Text(minutes == 0 ? "Never" : "\(minutes) min").tag(minutes)
            }
        }

        Divider()

        if let msg = vm.statusMessage {
            Text(msg)
                .foregroundColor(.secondary)
            Divider()
        }

        Button("Reconnect") { vm.reconnect() }
        Button("Power Off") { vm.powerOff() }

        Divider()

        Button("Quit BozoBar") {
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Helpers

    private let standbyOptions: [UInt8] = [0, 5, 10, 20, 30, 60, 120]

    private var audioModeBinding: Binding<UInt8> {
        Binding(
            get: { vm.state.audioModeIndex ?? 0 },
            set: { vm.setAudioMode($0) }
        )
    }

    private var standbyBinding: Binding<UInt8> {
        Binding(
            get: { vm.state.standbyTimerMinutes ?? 0 },
            set: { vm.setStandbyTimer($0) }
        )
    }

    private func batteryIcon(_ pct: UInt8) -> String {
        switch pct {
        case 0..<13: "battery.0percent"
        case 13..<38: "battery.25percent"
        case 38..<63: "battery.50percent"
        case 63..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}
