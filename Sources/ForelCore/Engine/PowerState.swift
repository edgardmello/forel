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


import Foundation
import IOKit.ps

/// Values of the "Power source" condition, which keeps heavy rules (OCR,
/// conversions, uploads) for when the Mac is plugged in.
public enum PowerSourceValue: String, CaseIterable, Sendable {
    case powerAdapter = "power_adapter"
    case battery
    case lowPowerMode = "low_power_mode"

    public var label: String {
        switch self {
        case .powerAdapter: return "the power adapter"
        case .battery: return "the battery"
        case .lowPowerMode: return "in Low Power Mode"
        }
    }
}

/// What the Mac runs on right now.
public struct PowerState: Equatable, Sendable {
    public var onBattery: Bool
    public var lowPowerMode: Bool

    public init(onBattery: Bool, lowPowerMode: Bool) {
        self.onBattery = onBattery
        self.lowPowerMode = lowPowerMode
    }

    /// Tests pin the power state.
    @TaskLocal public static var override: PowerState? = nil

    public static var current: PowerState {
        if let override { return override }
        var onBattery = false
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? {
            onBattery = type == kIOPMBatteryPowerKey
        }
        return PowerState(onBattery: onBattery, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    func matches(_ value: PowerSourceValue) -> Bool {
        switch value {
        case .powerAdapter: return !onBattery
        case .battery: return onBattery
        case .lowPowerMode: return lowPowerMode
        }
    }
}
