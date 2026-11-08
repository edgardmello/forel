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

/// "Time of day", "Day of the week" and "Rule last ran": conditions that
/// depend on when a rule runs rather than on the file. Together with the
/// periodic re-check they schedule a rule ("weekdays after 08:00"), or
/// throttle it ("rule last ran is older than 10 minutes").
public enum ScheduleConditions {
    /// The current time for schedule conditions; tests pin it.
    @TaskLocal public static var clock: Date? = nil

    static var now: Date { clock ?? Date() }

    /// Minutes since midnight for "HH:mm" (24-hour), or nil.
    public static func minutes(_ value: String) -> Int? {
        let parts = value.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    public static func timeString(minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// "after 08:00" is true from 08:00 on; "before 18:00" until 17:59.
    static func matchTimeOfDay(_ op: Operator, _ value: String, at date: Date, calendar: Calendar = .current) -> Bool {
        guard let target = minutes(value) else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let current = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        switch op {
        case .after: return current >= target
        case .before: return current < target
        default: return false
        }
    }

    static func matchDayOfWeek(_ op: Operator, _ value: String, at date: Date, calendar: Calendar = .current) -> Bool {
        guard let day = WeekdayValue(rawValue: value) else { return false }
        let matches = day.includes(calendar.component(.weekday, from: date))
        switch op {
        case .is: return matches
        case .isNot: return !matches
        default: return false
        }
    }

    /// The next moment after `date` when a schedule condition in `rules`
    /// can change its answer: a "Time of day" boundary, or midnight for
    /// "Day of the week". Lets the app re-check rules right when a window
    /// opens instead of waiting for the next periodic re-check.
    public static func nextBoundary(after date: Date, rules: [Rule], calendar: Calendar = .current) -> Date? {
        var candidates: [Date] = []
        let startOfDay = calendar.startOfDay(for: date)
        for rule in rules where rule.enabled {
            for condition in rule.conditions {
                switch condition.kind {
                case .timeOfDay:
                    guard let minutes = minutes(condition.value) else { continue }
                    for dayOffset in 0...1 {
                        guard let day = calendar.date(byAdding: .day, value: dayOffset, to: startOfDay),
                              let boundary = calendar.date(byAdding: .minute, value: minutes, to: day),
                              boundary > date else { continue }
                        candidates.append(boundary)
                        break
                    }
                case .dayOfWeek:
                    if let midnight = calendar.date(byAdding: .day, value: 1, to: startOfDay) {
                        candidates.append(midnight)
                    }
                default:
                    continue
                }
            }
        }
        return candidates.min()
    }
}

/// Values of the "Day of the week" condition.
public enum WeekdayValue: String, CaseIterable, Sendable {
    case weekdays, weekend
    case monday, tuesday, wednesday, thursday, friday, saturday, sunday

    public var label: String {
        switch self {
        case .weekdays: return "a weekday (Mon–Fri)"
        case .weekend: return "the weekend"
        case .monday: return "Monday"
        case .tuesday: return "Tuesday"
        case .wednesday: return "Wednesday"
        case .thursday: return "Thursday"
        case .friday: return "Friday"
        case .saturday: return "Saturday"
        case .sunday: return "Sunday"
        }
    }

    /// `weekday` as `Calendar` numbers it: 1 is Sunday, 7 is Saturday.
    func includes(_ weekday: Int) -> Bool {
        switch self {
        case .weekdays: return (2...6).contains(weekday)
        case .weekend: return weekday == 1 || weekday == 7
        case .sunday: return weekday == 1
        case .monday: return weekday == 2
        case .tuesday: return weekday == 3
        case .wednesday: return weekday == 4
        case .thursday: return weekday == 5
        case .friday: return weekday == 6
        case .saturday: return weekday == 7
        }
    }
}
