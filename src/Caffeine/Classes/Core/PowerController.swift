//
//  PowerController.swift
//  Caffeine Plus
//

import AppKit
import Combine
import Foundation
import IOKit.pwr_mgt

protocol PowerAssertionHandling: AnyObject {
    var isHeld: Bool { get }
    func acquire(reason: String)
    func release()
}

/// Holds a PreventUserIdleSystemSleep assertion (display may still sleep).
final class IOKitPowerAssertion: PowerAssertionHandling {
    private var assertionID: IOPMAssertionID = 0
    private(set) var isHeld = false

    func acquire(reason: String) {
        guard !self.isHeld else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        if result == kIOReturnSuccess {
            self.assertionID = id
            self.isHeld = true
        }
    }

    func release() {
        guard self.isHeld else { return }
        IOPMAssertionRelease(self.assertionID)
        self.isHeld = false
    }

    deinit { self.release() }
}

enum OccurrenceState: String, Equatable {
    case pending, active, finished, skipped, interrupted
}

struct OccurrenceInfo: Identifiable, Equatable {
    let occurrence: Occurrence
    let state: OccurrenceState
    var id: String { self.occurrence.id }
}

/// Derives power behaviour from the store: wake before a window, hold the assertion from the
/// wake time until the end, release when no window is active. State is always recomputed from the
/// store and the clock, never from accumulated timers, so sleeps and clock changes are harmless.
@MainActor
final class PowerController: ObservableObject {
    static let horizon: TimeInterval = 14 * 86400
    static let maxScheduledWakes = 8

    @Published private(set) var upcoming: [OccurrenceInfo] = []
    @Published private(set) var wakeStatus: WakeStatus = .unknown

    /// The window currently holding the Mac awake, if any.
    var activeOccurrence: Occurrence? {
        self.upcoming.first { $0.state == .active }?.occurrence
    }

    private let store: ScheduleStore
    private let assertion: PowerAssertionHandling
    private let waker: WakeScheduling
    private let clock: () -> Date
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var started: Set<String> = []
    private var interrupted: Set<String> = []
    private var skipped: Set<String> = []
    private var syncTask: Task<Void, Never>?
    private var lastWakes: [Date]?

    init(store: ScheduleStore,
         assertion: PowerAssertionHandling = IOKitPowerAssertion(),
         waker: WakeScheduling,
         clock: @escaping () -> Date = Date.init,
         observeSystem: Bool = true)
    {
        self.store = store
        self.assertion = assertion
        self.waker = waker
        self.clock = clock

        self.store.$windows
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.reconcile() } }
            .store(in: &self.cancellables)

        if observeSystem {
            let center = NSWorkspace.shared.notificationCenter
            center.publisher(for: NSWorkspace.willSleepNotification)
                .sink { [weak self] _ in Task { @MainActor in self?.systemWillSleep() } }
                .store(in: &self.cancellables)
            center.publisher(for: NSWorkspace.didWakeNotification)
                .sink { [weak self] _ in Task { @MainActor in self?.reconcile() } }
                .store(in: &self.cancellables)
            NotificationCenter.default.publisher(for: .NSSystemClockDidChange)
                .sink { [weak self] _ in Task { @MainActor in self?.reconcile() } }
                .store(in: &self.cancellables)
        }
    }

    func start() {
        self.reconcile()
    }

    func stop() {
        self.timer?.invalidate()
        self.syncTask?.cancel()
        self.assertion.release()
    }

    /// Skips an occurrence (releases it now and does not wake for it).
    func skip(occurrenceID: String) {
        self.skipped.insert(occurrenceID)
        self.reconcile()
    }

    func refreshWakeAvailability() {
        Task { [waker] in
            let status = await waker.checkAvailability()
            await MainActor.run { self.wakeStatus = status; self.lastWakes = nil; self.reconcile() }
        }
    }

    func reconcile() {
        let now = self.clock()
        let all = ScheduleEngine.occurrences(
            of: self.store.windows,
            from: now.addingTimeInterval(-86400),
            to: now.addingTimeInterval(Self.horizon)
        )

        var infos: [OccurrenceInfo] = []
        var holding = false
        for occ in all {
            let state: OccurrenceState
            if self.skipped.contains(occ.id) {
                state = .skipped
            } else if now >= occ.end {
                state = self.interrupted.contains(occ.id) ? .interrupted : .finished
            } else if now >= occ.wakeAt {
                state = .active
                self.started.insert(occ.id)
                holding = true
            } else {
                state = .pending
            }
            infos.append(OccurrenceInfo(occurrence: occ, state: state))
        }
        self.upcoming = infos.filter { $0.state != .finished || $0.occurrence.end > now.addingTimeInterval(-3600) }

        if holding {
            self.assertion.acquire(reason: "Caffeine Plus: scheduled window")
        } else {
            self.assertion.release()
        }

        let wakes = infos
            .filter { $0.state == .pending && $0.occurrence.wakeAt > now.addingTimeInterval(10) }
            .map(\.occurrence.wakeAt)
            .prefix(Self.maxScheduledWakes)
        self.syncWakes(Array(wakes))
        self.armTimer(infos: infos, now: now)
    }

    // MARK: Private

    private func systemWillSleep() {
        let now = self.clock()
        for info in self.upcoming where info.state == .active && info.occurrence.end > now {
            self.interrupted.insert(info.occurrence.id)
        }
    }

    private func syncWakes(_ wakes: [Date]) {
        let normalized = wakes.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)) }
        guard normalized != self.lastWakes else { return }
        self.lastWakes = normalized
        self.syncTask?.cancel()
        self.syncTask = Task { [waker] in
            let status = await waker.sync(wakes: normalized)
            guard !Task.isCancelled else { return }
            await MainActor.run { self.wakeStatus = status }
        }
    }

    private func armTimer(infos: [OccurrenceInfo], now: Date) {
        self.timer?.invalidate()
        let boundaries = infos.flatMap { [$0.occurrence.wakeAt, $0.occurrence.end] }.filter { $0 > now }
        guard let next = boundaries.min() else { return }
        let timer = Timer(fire: next.addingTimeInterval(0.5), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
