import AppKit
import MITSchemeCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var appModel: AppModel?
    private var pendingOpenURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if !pendingOpenURLs.isEmpty, let appModel {
            let urls = pendingOpenURLs
            pendingOpenURLs.removeAll()
            appModel.openExternalFiles(urls)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let appModel {
            appModel.openExternalFiles(urls)
        } else {
            pendingOpenURLs.append(contentsOf: urls)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        appModel?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct MITSchemeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            WorkbenchView(model: appModel)
                .onAppear {
                    appDelegate.appModel = appModel
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Scheme Buffer") {
                    appModel.document.newDocument()
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Open…") {
                    appModel.document.openPanel()
                }
                .keyboardShortcut("o", modifiers: .command)

                Divider()

                Button("Save") {
                    _ = appModel.document.save()
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("Save As…") {
                    _ = appModel.document.saveAs()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }

            CommandMenu("Scheme") {
                Button("Evaluate Current Form") {
                    appModel.evaluateCurrentForm()
                }
                .keyboardShortcut(.return, modifiers: .command)

                Button("Evaluate Buffer") {
                    appModel.evaluateBuffer()
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])

                if let fileURL = appModel.document.fileURL {
                    Button("Load Current File into REPL") {
                        appModel.mode = .workbench
                        appModel.repl.loadFile(fileURL)
                    }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                }

                Divider()

                Button("Interrupt Evaluation") {
                    appModel.repl.interrupt()
                }
                .keyboardShortcut(".", modifiers: .command)

                Button("Restart REPL") {
                    appModel.repl.restart()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Clear REPL Transcript") {
                    appModel.repl.clearTranscript()
                }
                .keyboardShortcut("k", modifiers: .command)
            }

            CommandMenu("View") {
                Button("Workbench (Editor + REPL)") {
                    appModel.mode = .workbench
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Edwin Integrated Terminal") {
                    appModel.openCurrentFileInEdwin()
                }
                .keyboardShortcut("2", modifiers: .command)

                Divider()

                Toggle("Option Key as Meta in Edwin", isOn: $appModel.optionAsMeta)

                Divider()

                Button("Increase Font Size") {
                    appModel.fontSize = min(24, appModel.fontSize + 1)
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Decrease Font Size") {
                    appModel.fontSize = max(10, appModel.fontSize - 1)
                }
                .keyboardShortcut("-", modifiers: .command)
            }
        }
    }
}
