//
//  LaunchAtLogin.swift
//  Caffeine Plus
//

import Combine
import Foundation
import ServiceManagement

enum LoginItemStatus: Equatable {
    case enabled, disabled, requiresApproval
}

protocol LoginItemService {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

struct MainAppLoginItem: LoginItemService {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        default: .disabled
        }
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

/// Observable wrapper: the system is the source of truth, so `refresh()` re-reads it.
@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var status: LoginItemStatus
    @Published private(set) var errorMessage: String?

    private let service: LoginItemService

    init(service: LoginItemService = MainAppLoginItem()) {
        self.service = service
        self.status = service.status
    }

    var isEnabled: Bool { self.status == .enabled }

    func refresh() {
        self.status = self.service.status
    }

    func setEnabled(_ enabled: Bool) {
        self.errorMessage = nil
        do {
            if enabled {
                try self.service.register()
            } else if self.service.status != .disabled {
                try self.service.unregister()
            }
        } catch {
            self.errorMessage = error.localizedDescription
        }
        self.refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
