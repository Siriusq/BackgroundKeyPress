import SwiftUI

@main
struct BackgroundKeyPressApp: App {
    @StateObject private var controller = PressController()

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
                .frame(minWidth: 430)
        }
        .defaultSize(width: 460, height: 560)
        .windowResizability(.contentSize)
    }
}
