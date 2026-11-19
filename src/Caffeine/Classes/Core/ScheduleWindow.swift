//
//  ScheduleWindow.swift
//  Caffeine Plus
//

import Foundation

enum ScheduleError: Error, Equatable, LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case let .invalid(message): message
        }
    }
}

enum Weekday: String, Codable, CaseIterable {
    case sun, mon, tue, wed, thu, fri, sat

    /// Matches `Calendar.component(.weekday, …)` (Sunday = 1).
    var calendarValue: Int {
        switch self {
        case .sun: 1
        case .mon: 2
        case .tue: 3
        case .wed: 4
        case .thu: 5
        case .fri: 6
        case .sat: 7
        }
    }
}

struct Recurrence: Codable, Equatable {
    enum Kind: String, Codable {
        case none, daily, weekly
    }

    var kind: Kind
    var days: [Weekday]

    static let none = Recurrence(kind: .none, days: [])
    static let daily = Recurrence(kind: .daily, days: [])
    static func weekly(_ days: [Weekday]) -> Recurrence {
        Recurrence(kind: .weekly, days: days)
    }
}

/// A time span during which the Mac must stay awake.
struct ScheduleWindow: Codable, Equatable, Identifiable {
    static let defaultLeadMinutes = 5
    static let maxDurationMinutes = 24 * 60

    var id: String
    var title: String
    /// First occurrence. For recurring windows only its time of day (in `timeZoneID`) and day matter.
    var start: Date
    var timeZoneID: String
    var durationMinutes: Int
    var leadMinutes: Int
    var recurrence: Recurrence
    var enabled: Bool
    var source: String
    var updatedAt: Date

    var timeZone: TimeZone {
        TimeZone(identifier: self.timeZoneID) ?? .current
    }

    func validate() throws {
        guard !self.id.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ScheduleError.invalid("id must not be empty")
        }
        guard self.durationMinutes > 0, self.durationMinutes <= Self.maxDurationMinutes else {
            throw ScheduleError.invalid("duration_minutes must be between 1 and \(Self.maxDurationMinutes)")
        }
        guard self.leadMinutes >= 0, self.leadMinutes <= 120 else {
            throw ScheduleError.invalid("lead_minutes must be between 0 and 120")
        }
        guard TimeZone(identifier: self.timeZoneID) != nil else {
            throw ScheduleError.invalid("unknown timezone \(self.timeZoneID)")
        }
        if self.recurrence.kind == .weekly, self.recurrence.days.isEmpty {
            throw ScheduleError.invalid("weekly recurrence needs at least one day")
        }
    }
}

struct Occurrence: Equatable, Identifiable {
    let windowID: String
    let title: String
    let start: Date
    let end: Date
    let wakeAt: Date

    var id: String {
        "\(self.windowID)@\(Int(self.start.timeIntervalSince1970))"
    }
}

enum ScheduleEngine {
    /// Occurrences whose [wakeAt, end) interval intersects [from, to).
    static func occurrences(of window: ScheduleWindow, from: Date, to: Date) -> [Occurrence] {
        guard window.enabled else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = window.timeZone
        let duration = TimeInterval(window.durationMinutes * 60)
        let lead = TimeInterval(window.leadMinutes * 60)

        func make(_ start: Date) -> Occurrence? {
            let occ = Occurrence(
                windowID: window.id,
                title: window.title,
                start: start,
                end: start.addingTimeInterval(duration),
                wakeAt: start.addingTimeInterval(-lead)
            )
            return occ.end > from && occ.wakeAt < to ? occ : nil
        }

        switch window.recurrence.kind {
        case .none:
            return make(window.start).map { [$0] } ?? []
        case .daily, .weekly:
            let time = calendar.dateComponents([.hour, .minute, .second], from: window.start)
            let firstDay = calendar.startOfDay(for: window.start)
            let scanFrom = max(firstDay, calendar.startOfDay(for: from.addingTimeInterval(-duration - 86400)))
            var day = scanFrom
            var result: [Occurrence] = []
            let wanted = Set(window.recurrence.days.map(\.calendarValue))
            while day < to.addingTimeInterval(lead + 86400) {
                let weekday = calendar.component(.weekday, from: day)
                if window.recurrence.kind == .daily || wanted.contains(weekday),
                   let start = calendar.date(
                       bySettingHour: time.hour ?? 0,
                       minute: time.minute ?? 0,
                       second: time.second ?? 0,
                       of: day
                   ),
                   let occ = make(start)
                {
                    result.append(occ)
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
            return result
        }
    }

    static func occurrences(of windows: [ScheduleWindow], from: Date, to: Date) -> [Occurrence] {
        windows.flatMap { self.occurrences(of: $0, from: from, to: to) }.sorted { $0.start < $1.start }
    }
}
