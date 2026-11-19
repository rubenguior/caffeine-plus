//
//  ScheduleStore.swift
//  Caffeine Plus
//

import Combine
import Foundation

enum AppPaths {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Caffeine Plus", isDirectory: true)
    }
}

/// Persistent, observable list of schedule windows (single source of truth).
@MainActor
final class ScheduleStore: ObservableObject {
    @Published private(set) var windows: [ScheduleWindow] = []

    private let fileURL: URL
    private let now: () -> Date

    init(fileURL: URL = AppPaths.supportDirectory.appendingPathComponent("schedules.json"),
         now: @escaping () -> Date = Date.init)
    {
        self.fileURL = fileURL
        self.now = now
        self.load()
    }

    /// Creates or replaces the window with the same id.
    @discardableResult
    func upsert(_ window: ScheduleWindow) throws -> ScheduleWindow {
        try window.validate()
        var stored = window
        stored.updatedAt = self.now()
        if let index = windows.firstIndex(where: { $0.id == window.id }) {
            self.windows[index] = stored
        } else {
            self.windows.append(stored)
        }
        try self.save()
        return stored
    }

    @discardableResult
    func delete(id: String) throws -> Bool {
        let before = self.windows.count
        self.windows.removeAll { $0.id == id }
        guard self.windows.count != before else { return false }
        try self.save()
        return true
    }

    func setEnabled(id: String, enabled: Bool) throws {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        self.windows[index].enabled = enabled
        try self.save()
    }

    func window(id: String) -> ScheduleWindow? {
        self.windows.first { $0.id == id }
    }

    // MARK: Persistence

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private func load() {
        guard let data = try? Data(contentsOf: self.fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            self.windows = try decoder.decode([ScheduleWindow].self, from: data)
        } catch {
            // Keep the unreadable file for inspection and start empty.
            let backup = self.fileURL.deletingLastPathComponent()
                .appendingPathComponent("schedules.corrupt-\(Int(self.now().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: self.fileURL, to: backup)
            self.windows = []
        }
    }

    private func save() throws {
        let directory = self.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(self.windows).write(to: self.fileURL, options: .atomic)
    }
}
