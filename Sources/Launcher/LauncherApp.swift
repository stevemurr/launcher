import Darwin
import SwiftUI

struct LauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@main
enum LauncherMain {
    static func main() {
        if ProcessPersistentShellSessionManager.runHelperIfRequested() {
            _exit(127)
        }
        LauncherApp.main()
    }
}
