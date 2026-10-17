import SwiftUI

@main
struct StreamVibesApp: App {
    @State private var db = DatabaseService()
    @State private var ai = AIService()
    @State private var buddy = BuddyChatController()

    private var buddyChatMenuLabel: String {
        if buddy.isPresented && !buddy.isMinimized { return "Hide Buddy Chat" }
        if buddy.isPresented && buddy.isMinimized { return "Open Buddy Chat" }
        return "Buddy Chat"
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .credentialStorageAlert()
                .environment(db)
                .environment(ai)
                .environment(buddy)
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(.dark)
                .onAppear {
                    // Open full screen
                    if let window = NSApplication.shared.windows.first {
                        window.setFrame(NSScreen.main?.visibleFrame ?? window.frame, display: true)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        Settings {
            SettingsView()
                .credentialStorageAlert()
                .environment(db)
                .environment(ai)
                .frame(minWidth: 500, minHeight: 500)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button(ai.isJobsPanelVisible ? "Hide Jobs" : "View Jobs") {
                    ai.toggleJobsPanel()
                }
                .keyboardShortcut("j", modifiers: [.command, .option])

                if !ai.recentOperations.isEmpty {
                    Button("Clear Finished Jobs") {
                        ai.clearFinishedOperations()
                    }
                }
            }
            CommandMenu("StreamVibes") {
                Button("Refresh") {
                    Task { try? await db.refreshAll() }
                }
                .keyboardShortcut("r", modifiers: .command)

                Button(buddyChatMenuLabel) {
                    buddy.toggle()
                }
                .keyboardShortcut("k", modifiers: .command)
            }
        }
    }
}
