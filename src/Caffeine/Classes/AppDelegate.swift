//
//  AppDelegate.swift
//  Caffeine Plus
//
//  Based on Caffeine by Dominic Rodemer (MIT).
//

import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var server: MCPHTTPServer?
    private var power: PowerController?

    func applicationDidFinishLaunching(_: Notification) {
        let store = ScheduleStore()
        let power = PowerController(store: store, waker: PmsetSudoWakeScheduler())
        let router = MCPRouter(store: store, power: power)
        let server = MCPHTTPServer(token: MCPHTTPServer.loadOrCreateToken()) { body in
            await MainActor.run { router.handle(body) }
        }
        do {
            try server.start()
        } catch {
            NSLog("Caffeine Plus: MCP server failed to start: \(error)")
        }
        self.server = server
        self.power = power

        self.menuBarController = MenuBarController(store: store, power: power)
        power.start()

        // Hide the dock icon - this is a menu bar only app
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_: Notification) {
        self.server?.stop()
        self.power?.stop()
        self.menuBarController?.cleanup()
    }
}
