// Forel - A native macOS file-automation app
// Copyright (C) 2026  Lab421
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import SwiftUI
import ForelCore

@main
struct ForelMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model: AppModel
    @StateObject private var updater: UpdaterManager

    /// Held for the life of the process; see `InstanceLock`.
    private static var instanceLock: InstanceLock?

    init() {
        let appSupport = try! AppModel.prepareAppSupportDirectory()
        let lockPath = appSupport.appendingPathComponent("forel.lock").path
        guard let instanceLock = InstanceLock(path: lockPath) else {
            SingleInstance.handOffToRunningInstance(lockPath: lockPath)
        }
        Self.instanceLock = instanceLock

        let model = try! AppModel(appSupport: appSupport)
        _model = StateObject(wrappedValue: model)
        let updater = UpdaterManager(db: model.db)
        _updater = StateObject(wrappedValue: updater)
        AppDelegate.launchContext = (model, updater)
    }

    var body: some Scene {
        // A single `Window` rather than a `WindowGroup`: Forel has one main
        // window, so File has no "New Window" item that would open a second
        // one, and reopening after the window was closed brings back that
        // same window instead of adding another.
        Window("Forel", id: AppDelegate.mainWindowID) {
            ContentView()
                .environmentObject(model)
                .environmentObject(updater)
                .frame(minWidth: 960, minHeight: 520)
                .background(WindowAccessor { appDelegate.mainWindowDidAttach($0) })
                .background(OpenWindowAccessor { appDelegate.openWindow = $0 })
                .onAppear {
                    appDelegate.configure(model: model, updater: updater)
                }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 620)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Forel") {
                    var options: [NSApplication.AboutPanelOptionKey: Any] = [
                        .applicationName: AppInfo.name,
                        .applicationVersion: AppInfo.version,
                        .version: "Build \(AppInfo.build)",
                        .credits: Self.aboutCredits,
                    ]

                    if let icon = Bundle.module.url(forResource: "AppIcon", withExtension: "png")
                        .flatMap({ NSImage(contentsOf: $0) }) {
                        options[.applicationIcon] = icon
                    }

                    NSApplication.shared.orderFrontStandardAboutPanel(options: options)
                }
            }
        }

        // A real `Settings` scene (not an in-app route) so Settings behaves
        // like every other macOS app: its own window, a "Settings…" item
        // under the Forel menu, and the standard ⌘, shortcut, all wired up
        // automatically by SwiftUI.
        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(updater)
        }
        .windowResizability(.contentSize)
    }

    private static var aboutCredits: NSAttributedString {
        let credits = NSMutableAttributedString(
            string: "\nGitHub Repository",
            attributes: [.link: AppInfo.repositoryURL]
        )

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        credits.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: 0, length: credits.length)
        )
        return credits
    }
}
