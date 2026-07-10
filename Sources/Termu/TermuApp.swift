import AppKit
import SwiftUI

extension Notification.Name {
    static let termuRequestDeleteSelectedHost = Notification.Name("Termu.requestDeleteSelectedHost")
    static let termuRequestToggleSidebar = Notification.Name("Termu.requestToggleSidebar")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    func application(_ app: NSApplication, shouldSaveApplicationState coder: NSCoder) -> Bool {
        false
    }

    func application(_ app: NSApplication, shouldRestoreApplicationState coder: NSCoder) -> Bool {
        false
    }
}

@main
struct TermuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = ConfigurationStore()
    @State private var systemColorScheme = SystemAppearance.colorScheme

    var body: some Scene {
        WindowGroup("Termu") {
            ContentView()
                .environmentObject(store)
                .preferredColorScheme(
                    store.configuration.terminalTheme.preferredColorScheme(
                        systemColorScheme: systemColorScheme
                    )
                )
                .onReceive(DistributedNotificationCenter.default().publisher(for: SystemAppearance.changedNotification)) { _ in
                    systemColorScheme = SystemAppearance.colorScheme
                }
                .frame(minWidth: 1040, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Host") {
                    store.addHost()
                }
                .keyboardShortcut("n", modifiers: [.command])
            }

            CommandGroup(after: .sidebar) {
                Button("Toggle Sidebar") {
                    NotificationCenter.default.post(name: .termuRequestToggleSidebar, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
            }

            CommandMenu("Host") {
                Button("Open in Terminal") {
                    store.connectSelectedHostInTerminal()
                }
                .keyboardShortcut("k", modifiers: [.command])
                .disabled(store.selectedHost == nil)

                Button("Delete Host") {
                    NotificationCenter.default.post(name: .termuRequestDeleteSelectedHost, object: nil)
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(store.selectedHost == nil)
            }
        }
    }
}
