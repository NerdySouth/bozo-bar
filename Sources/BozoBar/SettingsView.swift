import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var vm: HeadphoneViewModel
    @AppStorage("showBatteryInMenuBar") var showBattery = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Device
            if let name = vm.state.productName {
                HStack {
                    Label(name, systemImage: "headphones")
                    Spacer()
                    Button("Forget") { vm.forgetDevice() }
                        .controlSize(.small)
                }
            } else if UserDefaults.standard.string(forKey: "selectedDeviceUUID") != nil {
                HStack {
                    Label("Saved device", systemImage: "headphones")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Forget") { vm.forgetDevice() }
                        .controlSize(.small)
                }
            }

            Divider()

            Toggle("Launch at Login", isOn: $launchAtLogin)
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: launchAtLogin) { enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }

            Toggle("Show Battery in Menu Bar", isOn: $showBattery)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}
