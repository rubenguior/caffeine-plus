//
//  ScheduleView.swift
//  Caffeine Plus
//

import SwiftUI

struct ScheduleView: View {
    @ObservedObject var power: PowerController
    @ObservedObject var store: ScheduleStore
    let mcpURL: String
    let tokenPath: String
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            self.warningBanner
            if self.power.upcoming.isEmpty {
                Text("No scheduled windows. Claude can register them through the MCP server.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("ScheduleView.emptyLabel")
            } else {
                List(self.power.upcoming) { info in
                    self.row(info)
                }
                .accessibilityIdentifier("ScheduleView.list")
            }
            self.mcpInfo
        }
        .padding()
        .frame(minWidth: 520, minHeight: 360)
        .onAppear { self.power.refreshWakeAvailability() }
    }

    @ViewBuilder
    private var warningBanner: some View {
        if case let .unavailable(reason) = self.power.wakeStatus {
            VStack(alignment: .leading, spacing: 6) {
                Label("Scheduled wake is not available", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text("\(reason). The Mac only stays awake during a window if it is already awake.")
                    .font(.callout)
                HStack {
                    Button("Allow wake scheduling…") {
                        self.message = SudoersInstaller.install()
                            ? nil : String(localized: "Installation was cancelled or failed.")
                        self.power.refreshWakeAvailability()
                    }
                    .accessibilityHint(Text("Installs a limited sudo rule for pmset schedule after asking for an administrator password"))
                    if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
                }
            }
            .padding(10)
            .background(.yellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
        } else if self.power.wakeStatus == .ready {
            Label("Scheduled wake is ready", systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ info: OccurrenceInfo) -> some View {
        let occ = info.occurrence
        let enabled = self.store.window(id: occ.windowID)?.enabled ?? false
        return HStack {
            VStack(alignment: .leading) {
                Text(occ.title).font(.headline)
                Text("\(occ.start.formatted(date: .abbreviated, time: .shortened)) – \(occ.end.formatted(date: .omitted, time: .shortened))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Self.label(info.state)).foregroundStyle(.secondary)
            if info.state == .pending || info.state == .active {
                Button("Skip") { self.power.skip(occurrenceID: info.id) }
                    .accessibilityLabel(Text("Skip \(occ.title)"))
            }
            Toggle("Enabled", isOn: Binding(
                get: { enabled },
                set: { try? self.store.setEnabled(id: occ.windowID, enabled: $0) }
            ))
            .labelsHidden()
            .accessibilityLabel(Text("Enabled: \(occ.title)"))
            Button(role: .destructive) {
                _ = try? self.store.delete(id: occ.windowID)
            } label: { Image(systemName: "trash") }
                .accessibilityLabel(Text("Delete \(occ.title)"))
        }
        .accessibilityElement(children: .contain)
    }

    private var mcpInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MCP server").font(.headline)
            Text("claude mcp add --transport http caffeine-plus \(self.mcpURL) --header \"Authorization: Bearer $(cat '\(self.tokenPath)')\"")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityLabel(Text("Command to register the MCP server in Claude Code"))
        }
    }

    private static func label(_ state: OccurrenceState) -> LocalizedStringKey {
        switch state {
        case .pending: "Pending"
        case .active: "In progress"
        case .finished: "Finished"
        case .skipped: "Skipped"
        case .interrupted: "Interrupted"
        }
    }
}
