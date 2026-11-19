//
//  MCPRouter.swift
//  Caffeine Plus
//

import Foundation

/// Minimal MCP (JSON-RPC 2.0) request handler exposing the schedule tools.
@MainActor
final class MCPRouter {
    static let protocolVersion = "2025-06-18"

    private let store: ScheduleStore
    private let power: PowerController
    private let now: () -> Date

    init(store: ScheduleStore, power: PowerController, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.power = power
        self.now = now
    }

    /// Returns the JSON response body, or nil for notifications.
    func handle(_ body: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: body),
              let request = object as? [String: Any],
              let method = request["method"] as? String
        else {
            return Self.encode(Self.error(id: NSNull(), code: -32700, message: "Parse error"))
        }
        guard let id = request["id"] else { return nil } // notification
        let params = request["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return Self.encode(Self.result(id: id, [
                "protocolVersion": Self.protocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "caffeine-plus", "version": "0.1.0"],
                "instructions": "Registers time windows in which the Mac must stay awake. Use the same id for a "
                    + "Claude scheduled task every time you create or change it (upsert_window is idempotent). "
                    + "Call delete_window when the task is removed.",
            ]))
        case "ping":
            return Self.encode(Self.result(id: id, [:]))
        case "tools/list":
            return Self.encode(Self.result(id: id, ["tools": Self.tools]))
        case "tools/call":
            guard let name = params["name"] as? String else {
                return Self.encode(Self.error(id: id, code: -32602, message: "Missing tool name"))
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let output = try self.call(name, args)
                return Self.encode(Self.result(id: id, Self.content(output, isError: false)))
            } catch {
                return Self.encode(Self.result(id: id, Self.content(
                    ["error": error.localizedDescription], isError: true
                )))
            }
        default:
            return Self.encode(Self.error(id: id, code: -32601, message: "Method not found"))
        }
    }

    // MARK: Tools

    private func call(_ name: String, _ args: [String: Any]) throws -> [String: Any] {
        switch name {
        case "list_windows":
            return ["windows": self.store.windows.map(self.describe)]
        case "upsert_window":
            let window = try self.parseWindow(args)
            let stored = try self.store.upsert(window)
            self.power.reconcile()
            return ["window": self.describe(stored), "status": self.status()]
        case "delete_window":
            guard let id = args["id"] as? String else { throw ScheduleError.invalid("id is required") }
            let removed = try self.store.delete(id: id)
            self.power.reconcile()
            return ["deleted": removed]
        case "get_status":
            return self.status()
        default:
            throw ScheduleError.invalid("Unknown tool \(name)")
        }
    }

    private func status() -> [String: Any] {
        let wake: String
        var warnings: [String] = []
        switch self.power.wakeStatus {
        case .ready: wake = "ready"
        case .unknown: wake = "unknown"
        case let .unavailable(reason):
            wake = "unavailable"
            warnings.append("Scheduled wake is not available: \(reason). The Mac stays awake during windows only if it is already awake.")
        }
        let next = self.power.upcoming.first { $0.state == .pending || $0.state == .active }
        var result: [String: Any] = [
            "wake_scheduling": wake,
            "active_windows": self.power.upcoming.filter { $0.state == .active }.map(\.occurrence.windowID),
            "warnings": warnings + ["A closed lid on battery power may still put the Mac to sleep (macOS limitation)."],
        ]
        if let next {
            result["next"] = [
                "id": next.occurrence.windowID,
                "start": Self.iso(next.occurrence.start, TimeZone.current),
                "state": next.state.rawValue,
            ]
        }
        return result
    }

    private func describe(_ window: ScheduleWindow) -> [String: Any] {
        var recurrence: [String: Any] = ["type": window.recurrence.kind.rawValue]
        if window.recurrence.kind == .weekly { recurrence["days"] = window.recurrence.days.map(\.rawValue) }
        return [
            "id": window.id,
            "title": window.title,
            "start": Self.iso(window.start, window.timeZone),
            "timezone": window.timeZoneID,
            "duration_minutes": window.durationMinutes,
            "lead_minutes": window.leadMinutes,
            "recurrence": recurrence,
            "enabled": window.enabled,
            "source": window.source,
        ]
    }

    private func parseWindow(_ args: [String: Any]) throws -> ScheduleWindow {
        guard let id = args["id"] as? String else { throw ScheduleError.invalid("id is required") }
        guard let startText = args["start"] as? String else { throw ScheduleError.invalid("start is required") }
        guard let duration = Self.int(args["duration_minutes"]) else {
            throw ScheduleError.invalid("duration_minutes is required")
        }
        let existing = self.store.window(id: id)
        let tzID = (args["timezone"] as? String) ?? existing?.timeZoneID ?? TimeZone.current.identifier
        guard let zone = TimeZone(identifier: tzID) else { throw ScheduleError.invalid("unknown timezone \(tzID)") }
        guard let start = Self.parseDate(startText, zone: zone) else {
            throw ScheduleError.invalid("start must be ISO 8601, e.g. 2026-11-20T09:00 or 2026-11-20T09:00:00+01:00")
        }

        var recurrence = Recurrence.none
        if let raw = args["recurrence"] as? [String: Any] {
            guard let type = (raw["type"] as? String).flatMap(Recurrence.Kind.init(rawValue:)) else {
                throw ScheduleError.invalid("recurrence.type must be none, daily or weekly")
            }
            let days = try ((raw["days"] as? [String]) ?? []).map { token -> Weekday in
                guard let day = Weekday(rawValue: token.lowercased()) else {
                    throw ScheduleError.invalid("unknown weekday \(token) (use mon…sun)")
                }
                return day
            }
            recurrence = Recurrence(kind: type, days: days)
        }

        return ScheduleWindow(
            id: id,
            title: (args["title"] as? String) ?? existing?.title ?? id,
            start: start,
            timeZoneID: tzID,
            durationMinutes: duration,
            leadMinutes: Self.int(args["lead_minutes"]) ?? existing?.leadMinutes ?? ScheduleWindow.defaultLeadMinutes,
            recurrence: recurrence,
            enabled: (args["enabled"] as? Bool) ?? true,
            source: (args["source"] as? String) ?? existing?.source ?? "claude",
            updatedAt: self.now()
        )
    }

    // MARK: Helpers

    nonisolated static func parseDate(_ text: String, zone: TimeZone) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = zone
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    nonisolated static func iso(_ date: Date, _ zone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = zone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func int(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double, double == double.rounded() { return Int(double) }
        return nil
    }

    private static func content(_ payload: [String: Any], isError: Bool) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return [
            "content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]],
            "isError": isError,
        ]
    }

    private static func result(id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private static func encode(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object)
    }

    static let tools: [[String: Any]] = [
        [
            "name": "list_windows",
            "description": "List the registered awake windows.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
        ],
        [
            "name": "upsert_window",
            "description": "Create or replace an awake window. Use the Claude scheduled task id as `id` so later edits replace it. The Mac wakes lead_minutes before start and stays awake until start + duration.",
            "inputSchema": [
                "type": "object",
                "required": ["id", "start", "duration_minutes"],
                "properties": [
                    "id": ["type": "string", "description": "Stable id, e.g. the scheduled task id"],
                    "title": ["type": "string"],
                    "start": ["type": "string", "description": "ISO 8601. Without offset it is read in `timezone`. For recurring windows only the time of day (and first date) matter."],
                    "duration_minutes": ["type": "integer", "minimum": 1, "maximum": 1440],
                    "lead_minutes": ["type": "integer", "minimum": 0, "maximum": 120, "description": "Wake this long before start (default 5)"],
                    "timezone": ["type": "string", "description": "IANA zone, default the Mac's"],
                    "recurrence": [
                        "type": "object",
                        "properties": [
                            "type": ["type": "string", "enum": ["none", "daily", "weekly"]],
                            "days": ["type": "array", "items": ["type": "string", "enum": ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]]],
                        ],
                    ],
                    "enabled": ["type": "boolean"],
                    "source": ["type": "string"],
                ],
            ],
        ],
        [
            "name": "delete_window",
            "description": "Delete an awake window by id (call when the scheduled task is deleted).",
            "inputSchema": ["type": "object", "required": ["id"], "properties": ["id": ["type": "string"]]],
        ],
        [
            "name": "get_status",
            "description": "Wake scheduling availability, active windows, next window and warnings.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
        ],
    ]
}
