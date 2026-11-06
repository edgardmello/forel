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

import AppKit
import SwiftUI

/// Forel lives in the Dock only while one of its windows is open: showing a
/// window switches it to a regular app (Dock icon, menu bar, Cmd-Tab), and
/// closing the last one drops it back to a menu-bar-only accessory app.
@MainActor
enum WindowActivation {
    static func activate(_ window: NSWindow?) {
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: activationOptions)
    }

    /// Activating synchronously right after a window is shown or a popover
    /// is dismissed races the window server and the accessory→regular
    /// activation-policy switch (which needs a moment to take effect), and
    /// can leave Forel's menu bar (Forel/File/Edit/View…) not swapped in
    /// even though the window itself comes to the front. Deferring a tick,
    /// then again shortly after, avoids that race — use this instead of
    /// calling `activate` directly from a UI action.
    ///
    /// With `onlyIfVisible`, a window that isn't on screen by then is left
    /// alone rather than shown — for windows SwiftUI creates but may keep
    /// hidden, such as at a login-item launch.
    static func activateSoon(_ window: NSWindow?, onlyIfVisible: Bool = false) {
        let activateIfWanted = { [weak window] in
            if onlyIfVisible, window?.isVisible != true { return }
            activate(window)
        }
        DispatchQueue.main.async(execute: activateIfWanted)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: activateIfWanted)
    }

    /// Windows that keep Forel in the Dock: titled, non-panel windows that
    /// are on screen or minimized. Excludes the menu bar item's own window
    /// and its popover, which aren't titled.
    static func hasUserFacingWindow(excluding excluded: NSWindow? = nil) -> Bool {
        NSApp.windows.contains { window in
            window !== excluded
                && !(window is NSPanel)
                && window.styleMask.contains(.titled)
                && (window.isVisible || window.isMiniaturized)
        }
    }

    /// Puts Forel back in the Dock when one of its windows is shown by a
    /// path that didn't go through `activate` (e.g. SwiftUI reopening the
    /// main window itself).
    static func enterDockIfNeeded(for window: NSWindow?) {
        guard let window, NSApp.activationPolicy() != .regular,
              !(window is NSPanel), window.styleMask.contains(.titled) else { return }
        activateSoon(window)
    }

    /// Leaves the Dock once no Forel window is left open.
    static func leaveDockIfNoWindowsRemain(excluding excluded: NSWindow? = nil) {
        guard !hasUserFacingWindow(excluding: excluded) else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    private static var activationOptions: NSApplication.ActivationOptions {
        // rawValue 1 is the legacy "ignore other apps" bit, kept without
        // referencing the deprecated symbol directly. Deliberately excludes
        // rawValue 2 (`.activateAllWindows`): that flag un-hides *every*
        // window of the app on activation, including ones intentionally
        // ordered out (e.g. the main window while only Settings should be
        // shown) — it was the cause of "Settings" in the quick panel opening
        // the main Forel window instead.
        NSApplication.ActivationOptions(rawValue: 1)
    }
}

struct WindowActivationBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            WindowActivation.activate(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            WindowActivation.activate(nsView.window)
        }
    }
}

/// Reports the `NSWindow` hosting a SwiftUI view once the view is attached
/// to it, for code that needs the real window rather than a guess from
/// `NSApp.windows`.
struct WindowAccessor: NSViewRepresentable {
    let onAttach: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        AttachmentView(onAttach: onAttach)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class AttachmentView: NSView {
        private let onAttach: @MainActor (NSWindow) -> Void

        init(onAttach: @escaping @MainActor (NSWindow) -> Void) {
            self.onAttach = onAttach
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                onAttach(window)
            }
        }
    }
}

/// Hands SwiftUI's `openWindow` action to AppKit code. The action stays
/// usable after the window that provided it is closed, which is how the app
/// delegate recreates the main window from the menu bar or a reopen event.
struct OpenWindowAccessor: View {
    @Environment(\.openWindow) private var openWindow
    let onAppear: @MainActor (OpenWindowAction) -> Void

    var body: some View {
        Color.clear.onAppear { onAppear(openWindow) }
    }
}
