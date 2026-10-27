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
import ForelCore

/// What a second launch does when Forel is already running (`open -n`, a dev
/// build next to the installed app): show the running instance's main window
/// instead, then quit before opening the database or watching anything.
enum SingleInstance {
    static let showMainWindowNotification = Notification.Name("com.lab421.forel.showMainWindow")

    static func handOffToRunningInstance(lockPath: String) -> Never {
        // Activated from here, while this process is still the one the user
        // just launched; the running instance can't take focus on its own.
        if let pid = InstanceLock.holderPID(path: lockPath),
           let running = NSRunningApplication(processIdentifier: pid) {
            running.activate(options: NSApplication.ActivationOptions(rawValue: 1))
        }
        DistributedNotificationCenter.default().postNotificationName(
            showMainWindowNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        exit(0)
    }
}
