import SwiftUI

/// `swift run` launches a bare executable with no .app bundle, so macOS treats it as a
/// background process. Promote it so the window and Dock icon appear. Harmless in a real bundle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct HomebaseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        NavigationSplitView {
            List {
                Text("No servers yet")
            }
            .navigationTitle("Homebase")
        } detail: {
            ContentUnavailableView("Select a server", systemImage: "server.rack")
        }
        .frame(minWidth: 700, minHeight: 450)
    }
}
