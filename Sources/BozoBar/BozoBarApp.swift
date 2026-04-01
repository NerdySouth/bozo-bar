import SwiftUI

@main
struct BozoBarApp: App {
    @StateObject private var vm = HeadphoneViewModel()
    @AppStorage("showBatteryInMenuBar") private var showBattery = true

    var body: some Scene {
        MenuBarExtra {
            MenuContent(vm: vm)
                .frame(width: 300)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "headphones")
                if showBattery {
                    Text(vm.menuBarTitle)
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
