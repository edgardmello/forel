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
import Testing
@testable import ForelCore

struct ScheduleConditionTests {
    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: string)!
    }

    @Test func timeOfDayMatchesAWindow() {
        let file = TempDir().file("x.txt", contents: "x")
        let after = makeCondition(.timeOfDay, .after, "08:00")
        let before = makeCondition(.timeOfDay, .before, "18:00")
        ScheduleConditions.$clock.withValue(date("2026-11-09 07:59")) {
            #expect(!ConditionEvaluator.evaluate(after, path: file))
            #expect(ConditionEvaluator.evaluate(before, path: file))
        }
        ScheduleConditions.$clock.withValue(date("2026-11-09 08:00")) {
            #expect(ConditionEvaluator.evaluate(after, path: file))
        }
        ScheduleConditions.$clock.withValue(date("2026-11-09 18:00")) {
            #expect(!ConditionEvaluator.evaluate(before, path: file))
        }
        #expect(ScheduleConditions.minutes("24:00") == nil)
        #expect(ScheduleConditions.minutes("7:05") == 425)
    }

    @Test func dayOfWeekMatchesWeekdaysAndNamedDays() {
        let file = TempDir().file("x.txt", contents: "x")
        // 2026-11-09 is a Monday, 2026-11-08 a Sunday.
        ScheduleConditions.$clock.withValue(date("2026-11-09 12:00")) {
            #expect(ConditionEvaluator.evaluate(makeCondition(.dayOfWeek, .is, "weekdays"), path: file))
            #expect(ConditionEvaluator.evaluate(makeCondition(.dayOfWeek, .is, "monday"), path: file))
            #expect(!ConditionEvaluator.evaluate(makeCondition(.dayOfWeek, .is, "weekend"), path: file))
        }
        ScheduleConditions.$clock.withValue(date("2026-11-08 12:00")) {
            #expect(ConditionEvaluator.evaluate(makeCondition(.dayOfWeek, .is, "sunday"), path: file))
            #expect(ConditionEvaluator.evaluate(makeCondition(.dayOfWeek, .isNot, "weekdays"), path: file))
        }
    }

    @Test func scheduleRulesAreReCheckedAndBoundariesFound() {
        var rule = makeRule(name: "work hours")
        rule.conditions = [makeCondition(.timeOfDay, .after, "08:00"), makeCondition(.timeOfDay, .before, "18:00")]
        #expect(RuleEngine.isTimeDependent(rule))
        #expect(ScheduleConditions.nextBoundary(after: date("2026-11-09 07:00"), rules: [rule]) == date("2026-11-09 08:00"))
        #expect(ScheduleConditions.nextBoundary(after: date("2026-11-09 12:00"), rules: [rule]) == date("2026-11-09 18:00"))
        #expect(ScheduleConditions.nextBoundary(after: date("2026-11-09 19:00"), rules: [rule]) == date("2026-11-10 08:00"))

        var daily = makeRule(name: "mondays")
        daily.conditions = [makeCondition(.dayOfWeek, .is, "monday")]
        #expect(ScheduleConditions.nextBoundary(after: date("2026-11-09 19:00"), rules: [daily]) == date("2026-11-10 00:00"))

        rule.enabled = false
        #expect(ScheduleConditions.nextBoundary(after: date("2026-11-09 07:00"), rules: [rule]) == nil)
    }

    @Test func validatorRejectsBadScheduleValues() {
        #expect(!RuleValidator.validate([makeCondition(.timeOfDay, .after, "8am")]).isEmpty)
        #expect(!RuleValidator.validate([makeCondition(.dayOfWeek, .is, "someday")]).isEmpty)
        #expect(RuleValidator.validate([makeCondition(.timeOfDay, .after, "08:30"), makeCondition(.dayOfWeek, .is, "weekend")]).isEmpty)
        #expect(RuleValidator.validate([makeCondition(.ruleLastRan, .olderThan, "10 minutes")]).isEmpty)
    }
}

struct PowerSourceConditionTests {
    @Test func powerSourceFollowsThePowerState() {
        let file = TempDir().file("x.txt", contents: "x")
        let plugged = makeCondition(.powerSource, .is, PowerSourceValue.powerAdapter.rawValue)
        let lowPower = makeCondition(.powerSource, .isNot, PowerSourceValue.lowPowerMode.rawValue)
        PowerState.$override.withValue(PowerState(onBattery: false, lowPowerMode: false)) {
            #expect(ConditionEvaluator.evaluate(plugged, path: file))
            #expect(ConditionEvaluator.evaluate(lowPower, path: file))
        }
        PowerState.$override.withValue(PowerState(onBattery: true, lowPowerMode: true)) {
            #expect(!ConditionEvaluator.evaluate(plugged, path: file))
            #expect(ConditionEvaluator.evaluate(makeCondition(.powerSource, .is, "battery"), path: file))
            #expect(!ConditionEvaluator.evaluate(lowPower, path: file))
        }
        var rule = makeRule(name: "plugged in")
        rule.conditions = [plugged]
        #expect(RuleEngine.isTimeDependent(rule))
        #expect(!RuleValidator.validate([makeCondition(.powerSource, .is, "solar")]).isEmpty)
    }
}
