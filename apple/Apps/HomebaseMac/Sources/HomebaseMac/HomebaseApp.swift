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
    @State private var host = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Host").foregroundStyle(.secondary)
                TextField("ssh host or ~/.ssh/config alias", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                Spacer()
            }
            .padding(12)
            Divider()
            TabView {
                CommandProbeView(host: host)
                    .tabItem { Text("Command") }
                TerminalPane(host: host)
                    .id(host)
                    .tabItem { Text("Terminal") }
            }
        }
        .frame(minWidth: 760, minHeight: 480)
    }
}
