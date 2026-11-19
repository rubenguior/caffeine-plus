//
//  WakeScheduler.swift
//  Caffeine Plus
//

import Foundation

nonisolated enum WakeStatus: Equatable {
    case unknown
    case ready
    case unavailable(String)
}

protocol WakeScheduling {
    /// Makes the OS wake events match `wakes` (only ones created by this app are touched).
    func sync(wakes: [Date]) async -> WakeStatus
    func checkAvailability() async -> WakeStatus
}

protocol CommandRunning {
    /// Returns the exit status.
    func run(_ launchPath: String, _ arguments: [String]) async -> Int32
}

struct ProcessRunner: CommandRunning {
    func run(_ launchPath: String, _ arguments: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: -1)
            }
        }
    }
}

/// Schedules wake events with `sudo -n pmset schedule`, which needs the narrow sudoers rule
/// installed by `SudoersInstaller`. Events it creates are tracked in a ledger so only those are cancelled.
actor PmsetSudoWakeScheduler: WakeScheduling {
    private let runner: CommandRunning
    private let ledgerURL: URL
    private let now: () -> Date

    init(runner: CommandRunning = ProcessRunner(),
         ledgerURL: URL = AppPaths.supportDirectory.appendingPathComponent("wake-ledger.json"),
         now: @escaping () -> Date = Date.init)
    {
        self.runner = runner
        self.ledgerURL = ledgerURL
        self.now = now
    }

    nonisolated static func pmsetDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "MM/dd/yy HH:mm:ss"
        return formatter.string(from: date)
    }

    func checkAvailability() async -> WakeStatus {
        let probe = Self.pmsetDate(Date(timeIntervalSince1970: 1_893_456_000))
        let status = await runner.run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "schedule", "wake", probe])
        return status == 0 ? .ready : .unavailable("sudo rule for pmset schedule is not installed")
    }

    /// Syncs run one after another: actor reentrancy at `await` would otherwise let two syncs read the
    /// same ledger and schedule the same wake twice.
    private var tail: Task<WakeStatus, Never>?

    func sync(wakes: [Date]) async -> WakeStatus {
        let previous = self.tail
        let task = Task { () -> WakeStatus in
            _ = await previous?.value
            return await self.perform(wakes: wakes)
        }
        self.tail = task
        return await task.value
    }

    private func perform(wakes: [Date]) async -> WakeStatus {
        let availability = await self.checkAvailability()
        guard availability == .ready else { return availability }

        let desired = Set(wakes.map { Int($0.timeIntervalSince1970) })
        let current = self.now().timeIntervalSince1970
        let ledger = self.loadLedger()
        var kept = Set<Int>()
        var failed = false

        for stamp in ledger {
            if desired.contains(stamp) {
                kept.insert(stamp)
            } else if Double(stamp) > current {
                let date = Self.pmsetDate(Date(timeIntervalSince1970: TimeInterval(stamp)))
                let status = await runner.run(
                    "/usr/bin/sudo",
                    ["-n", "/usr/bin/pmset", "schedule", "cancel", "wake", date]
                )
                if status != 0 { failed = true; kept.insert(stamp) }
            }
        }
        for stamp in desired.subtracting(kept) where Double(stamp) > current {
            let date = Self.pmsetDate(Date(timeIntervalSince1970: TimeInterval(stamp)))
            let status = await runner.run(
                "/usr/bin/sudo",
                ["-n", "/usr/bin/pmset", "schedule", "wake", date]
            )
            if status == 0 { kept.insert(stamp); self.saveLedger(kept) } else { failed = true }
        }
        self.saveLedger(kept)
        return failed ? .unavailable("pmset schedule failed") : .ready
    }

    private func loadLedger() -> Set<Int> {
        guard let data = try? Data(contentsOf: ledgerURL),
              let values = try? JSONDecoder().decode([Int].self, from: data) else { return [] }
        return Set(values)
    }

    private func saveLedger(_ values: Set<Int>) {
        try? FileManager.default.createDirectory(
            at: self.ledgerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? JSONEncoder().encode(values.sorted()).write(to: self.ledgerURL, options: .atomic)
    }
}

/// Installs / removes `/etc/sudoers.d/caffeineplus` (admin prompt, only on explicit user action).
enum SudoersInstaller {
    static let path = "/etc/sudoers.d/caffeineplus"

    static func rule(for user: String) -> String? {
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { return nil }
        return "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset schedule wake *, /usr/bin/pmset schedule cancel wake *"
    }

    @MainActor
    static func install() -> Bool {
        guard let rule = rule(for: NSUserName()) else { return false }
        let script = "T=$(mktemp) && printf '%s\\n' '\(rule)' > \"$T\" && /usr/sbin/visudo -cf \"$T\" && "
            + "/usr/bin/install -m 0440 -o root -g wheel \"$T\" \(self.path); R=$?; rm -f \"$T\"; exit $R"
        return self.runAsAdmin(script)
    }

    @MainActor
    static func uninstall() -> Bool {
        self.runAsAdmin("/bin/rm -f \(self.path)")
    }

    @MainActor
    private static func runAsAdmin(_ shell: String) -> Bool {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?
            .executeAndReturnError(&error)
        return error == nil
    }
}
