import SwiftUI

struct MenuContent: View {
    @ObservedObject var vm: HeadphoneViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "headphones")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.state.productName ?? "No Device")
                        .font(.headline)
                    if vm.state.connected {
                        Text("Connected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Disconnected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                // Battery
                if let batt = vm.state.battery.first {
                    HStack(spacing: 4) {
                        Image(systemName: batteryIcon(batt.percentage))
                        Text("\(batt.percentage)%")
                            .monospacedDigit()
                    }
                    .font(.callout)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // Audio mode
            if !vm.state.audioModes.isEmpty {
                sectionHeader("Audio Mode")
                Picker("Audio Mode", selection: audioModeBinding) {
                    ForEach(vm.state.audioModes) { mode in
                        Text(mode.name).tag(mode.modeIndex)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .padding(.horizontal, 8)
            }

            // Spatial audio
            if vm.state.spatialAudio != nil {
                Divider().padding(.vertical, 4)
                sectionHeader("Immersive Audio")
                Picker("Immersive Audio", selection: spatialAudioBinding) {
                    ForEach(SpatialAudioMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
            }

            Divider().padding(.vertical, 4)

            // Standby timer
            HStack {
                sectionHeader("Standby Timer")
                Spacer()
                Picker("Standby Timer", selection: standbyBinding) {
                    ForEach(standbyOptions, id: \.self) { minutes in
                        Text(minutes == 0 ? "Never" : "\(minutes) min").tag(minutes)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                .padding(.trailing, 12)
            }

            if let msg = vm.statusMessage {
                Divider().padding(.vertical, 4)
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }

            Divider().padding(.vertical, 4)

            // Actions
            HStack(spacing: 8) {
                Button("Reconnect") { vm.reconnect() }
                    .buttonStyle(.borderless)
                Button("Power Off") { vm.powerOff() }
                    .buttonStyle(.borderless)
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }

    private let standbyOptions: [UInt8] = [0, 5, 10, 20, 30, 60, 120]

    private var audioModeBinding: Binding<UInt8> {
        Binding(
            get: { vm.state.audioModeIndex ?? 0 },
            set: { vm.setAudioMode($0) }
        )
    }

    private var spatialAudioBinding: Binding<SpatialAudioMode> {
        Binding(
            get: { vm.state.spatialAudio ?? .off },
            set: { vm.setSpatialAudio($0) }
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
