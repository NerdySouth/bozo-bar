import SwiftUI

@main
struct BozoBarApp: App {
    @StateObject private var vm = HeadphoneViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(vm: vm)
                .frame(width: 300)
        } label: {
            Label {
                Text(vm.menuBarTitle)
            } icon: {
                Image(systemName: "headphones")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
