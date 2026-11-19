//
//  WindowDraft.swift
//  Caffeine Plus
//

import Foundation

/// Editable form state for a `ScheduleWindow` (manual create/edit).
struct WindowDraft: Identifiable, Equatable {
    let id: String
    let isNew: Bool
    var title: String
    var start: Date
    var timeZoneID: String
    var durationMinutes: Int
    var leadMinutes: Int
    var kind: Recurrence.Kind
    var days: Set<Weekday>
    var enabled: Bool
    var source: String

    init(newAt now: Date = Date()) {
        let next = Date(timeIntervalSince1970: ((now.timeIntervalSince1970 / 900).rounded(.up) + 1) * 900)
        self.id = "manual-\(UUID().uuidString.prefix(8).lowercased())"
        self.isNew = true
        self.title = ""
        self.start = next
        self.timeZoneID = TimeZone.current.identifier
        self.durationMinutes = 30
        self.leadMinutes = ScheduleWindow.defaultLeadMinutes
        self.kind = .none
        self.days = []
        self.enabled = true
        self.source = "manual"
    }

    init(_ window: ScheduleWindow) {
        self.id = window.id
        self.isNew = false
        self.title = window.title
        self.start = window.start
        self.timeZoneID = window.timeZoneID
        self.durationMinutes = window.durationMinutes
        self.leadMinutes = window.leadMinutes
        self.kind = window.recurrence.kind
        self.days = Set(window.recurrence.days)
        self.enabled = window.enabled
        self.source = window.source
    }

    /// Builds and validates the window (seconds are dropped from `start`).
    func makeWindow(now: Date = Date()) throws -> ScheduleWindow {
        let trimmed = self.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let whole = Date(timeIntervalSince1970: (self.start.timeIntervalSince1970 / 60).rounded(.down) * 60)
        let ordered = Weekday.allCases.filter { self.days.contains($0) }
        let window = ScheduleWindow(
            id: self.id,
            title: trimmed.isEmpty ? self.id : trimmed,
            start: whole,
            timeZoneID: self.timeZoneID,
            durationMinutes: self.durationMinutes,
            leadMinutes: self.leadMinutes,
            recurrence: Recurrence(kind: self.kind, days: self.kind == .weekly ? ordered : []),
            enabled: self.enabled,
            source: self.source,
            updatedAt: now
        )
        try window.validate()
        return window
    }
}
