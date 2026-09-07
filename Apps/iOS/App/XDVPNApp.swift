import SwiftUI

@main
struct XDVPNApp: App {
    @StateObject private var model = VPNModel()
    var body: some Scene {
        WindowGroup {
            ContentView(model: model).task {
                await model.load()
                #if DEBUG
                await model.runDebugValidationIfRequested()
                #endif
            }
        }
    }
}
