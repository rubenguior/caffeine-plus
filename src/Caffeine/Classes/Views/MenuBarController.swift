//
//  MenuBarController.swift
//  Caffeine
//
//  Created by Dominic Rodemer on 11.11.25.
//

import Cocoa
import Combine
import SwiftUI

@MainActor
class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var viewModel: CaffeineViewModel
    private var preferencesWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var scheduleWindow: NSWindow?
    private let store: ScheduleStore
    private let power: PowerController

    init(store: ScheduleStore, power: PowerController) {
        self.store = store
        self.power = power
        self.viewModel = CaffeineViewModel()
        super.init()
        self.setupMenuBar()
        self.setupObservers()

        // Ensure icon reflects the current state after full initialization
        // This is important because ViewModel.init() might activate if "activate at launch" is enabled
        self.updateIcon()
    }

    func cleanup() {
        self.viewModel.deactivate()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    private func setupMenuBar() {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem?.button else { return }

        // Set up button actions (icon will be set after observers are configured)
        button.action = #selector(self.statusItemClicked(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        button.setAccessibilityLabel("Caffeine")
        button.setAccessibilityIdentifier("MenuBarController.statusItem.button")
    }

    private func setupObservers() {
        self.viewModel.$isActive
            .sink { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.updateIcon()
                }
            }
            .store(in: &self.cancellables)

        self.power.$upcoming
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateIcon() }
            }
            .store(in: &self.cancellables)

        self.viewModel.$showPreferences
            .sink { [weak self] show in
                if show {
                    self?.showPreferencesWindow()
                }
            }
            .store(in: &self.cancellables)
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }

        let awake = self.viewModel.isActive || self.power.activeOccurrence != nil
        let imageName = awake ? "active" : "inactive"
        if let image = NSImage(named: NSImage.Name(imageName)) {
            button.image = image
        }

        if awake {
            button.setAccessibilityValue(NSLocalizedString(
                "Active, sleep prevented",
                tableName: "Accessibility",
                comment: "Accessibility value announced when Caffeine is preventing sleep"
            ))
        } else {
            button.setAccessibilityValue(NSLocalizedString(
                "Inactive, sleep allowed",
                tableName: "Accessibility",
                comment: "Accessibility value announced when Caffeine is not preventing sleep"
            ))
        }
    }

    @objc
    private func statusItemClicked(_: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp || (event.type == .leftMouseUp && event.modifierFlags.contains(.control)) {
            self.showContextMenu()
        } else {
            self.viewModel.toggleActive()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        // Schedule window currently keeping the Mac awake
        if let occurrence = self.power.activeOccurrence {
            let text = String(
                format: String(localized: "Schedule: %@ until %@"),
                occurrence.title,
                occurrence.end.formatted(date: .omitted, time: .shortened)
            )
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.setAccessibilityIdentifier("MenuBarController.scheduleStatusMenuItem")
            menu.addItem(item)
            menu.addItem(NSMenuItem.separator())
        }

        // Status info (only show if active)
        if self.viewModel.isActive, let timeString = viewModel.formattedTimeRemaining() {
            let infoItem = NSMenuItem(title: timeString, action: nil, keyEquivalent: "")
            infoItem.isEnabled = false
            infoItem.setAccessibilityIdentifier("MenuBarController.statusMenuItem")
            menu.addItem(infoItem)
            menu.addItem(NSMenuItem.separator())
        }

        // Duration options in submenu
        let activateForItem = NSMenuItem(
            title: String(localized: "Activate for"),
            action: nil,
            keyEquivalent: ""
        )
        activateForItem.setAccessibilityIdentifier("MenuBarController.activateForMenuItem")
        let submenu = NSMenu()

        var durations: [(String, Int)] = [
            (String(localized: "Indefinitely"), 0),
            (String(localized: "5 minutes"), 5),
            (String(localized: "10 minutes"), 10),
            (String(localized: "15 minutes"), 15),
            (String(localized: "30 minutes"), 30),
            (String(localized: "1 hour"), 60),
            (String(localized: "2 hours"), 120),
            (String(localized: "5 hours"), 300),
        ]

        #if DEBUG
        durations.insert((String(localized: "1 minute"), 1), at: 1)
        #endif

        for (title, minutes) in durations {
            let item = NSMenuItem(
                title: title,
                action: #selector(activateWithDuration(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = minutes
            item.setAccessibilityLabel(String(
                format: NSLocalizedString(
                    "Activate: %@",
                    tableName: "Accessibility",
                    comment: "Accessibility label for a duration menu item, %@ is the duration"
                ),
                title
            ))
            item.setAccessibilityIdentifier("MenuBarController.durationMenuItem.\(minutes)")
            submenu.addItem(item)
        }

        activateForItem.submenu = submenu
        menu.addItem(activateForItem)

        menu.addItem(NSMenuItem.separator())

        // Preferences
        let prefsItem = NSMenuItem(
            title: String(localized: "Preferences..."),
            action: #selector(showPreferences(_:)),
            keyEquivalent: ","
        )
        prefsItem.target = self
        prefsItem.setAccessibilityIdentifier("MenuBarController.preferencesMenuItem")
        menu.addItem(prefsItem)

        // About
        let aboutItem = NSMenuItem(
            title: String(localized: "About Caffeine Plus"),
            action: #selector(showAbout(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = self
        aboutItem.setAccessibilityIdentifier("MenuBarController.aboutMenuItem")
        menu.addItem(aboutItem)

        // Schedules
        let schedulesItem = NSMenuItem(
            title: String(localized: "Schedules..."),
            action: #selector(showSchedules(_:)),
            keyEquivalent: ""
        )
        schedulesItem.target = self
        schedulesItem.setAccessibilityIdentifier("MenuBarController.schedulesMenuItem")
        menu.addItem(schedulesItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: String(localized: "Quit"),
            action: #selector(quit(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        quitItem.setAccessibilityIdentifier("MenuBarController.quitMenuItem")
        menu.addItem(quitItem)

        self.statusItem?.menu = menu
        self.statusItem?.button?.performClick(nil)
        self.statusItem?.menu = nil
    }

    @objc
    private func activateWithDuration(_ sender: NSMenuItem) {
        let minutes = sender.tag
        let seconds = minutes > 0 ? TimeInterval(minutes * 60) : 0
        self.viewModel.activate(withTimeout: seconds)
    }

    @objc
    private func showPreferences(_: Any?) {
        self.showPreferencesWindow()
    }

    @objc
    private func showSchedules(_: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        if self.scheduleWindow == nil {
            let view = ScheduleView(
                power: self.power,
                store: self.store,
                mcpURL: "http://127.0.0.1:\(MCPHTTPServer.defaultPort)/mcp",
                tokenPath: AppPaths.supportDirectory.appendingPathComponent("mcp-token").path
            )
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = String(localized: "Schedules")
            window.styleMask = [.titled, .closable, .resizable]
            window.setContentSize(NSSize(width: 640, height: 440))
            window.isReleasedWhenClosed = false
            window.center()
            self.scheduleWindow = window
        }
        self.scheduleWindow?.makeKeyAndOrderFront(nil)
    }

    private func showPreferencesWindow() {
        NSApp.activate(ignoringOtherApps: true)

        if self.preferencesWindow == nil {
            let contentView = PreferencesView(viewModel: viewModel)
            let hostingController = NSHostingController(rootView: contentView)

            let window = NSWindow(contentViewController: hostingController)
            window.title = String(localized: "Welcome to Caffeine")
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 640, height: 470))
            window.center()

            self.preferencesWindow = window
        }

        self.preferencesWindow?.makeKeyAndOrderFront(nil)
    }

    @objc
    private func showAbout(_: Any?) {
        NSApp.activate(ignoringOtherApps: true)

        let credits =
            String(
                localized: "Caffeine Plus © 2026 Rubén Guijarro\n\nBased on Caffeine:\n© 2006 Tomas Franzén\n© 2018 Michael Jones\n© 2022 Dominic Rodemer\nhttps://github.com/domzilla/Caffeine\n\nSource code:\nhttps://github.com/rubenguior/caffeine-plus"
            )

        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: credits),
        ])
    }

    @objc
    private func quit(_: Any?) {
        NSApp.terminate(nil)
    }
}
