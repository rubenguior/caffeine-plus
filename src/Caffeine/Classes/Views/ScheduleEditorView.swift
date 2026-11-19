//
//  ScheduleEditorView.swift
//  Caffeine Plus
//

import SwiftUI

struct ScheduleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: WindowDraft
    let onSave: (ScheduleWindow) throws -> Void
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(self.draft.isNew ? "New window" : "Edit window").font(.headline)
            Form {
                TextField("Title", text: self.$draft.title)
                    .accessibilityIdentifier("ScheduleEditor.title")
                DatePicker("Start", selection: self.$draft.start, displayedComponents: [.date, .hourAndMinute])
                    .environment(\.timeZone, TimeZone(identifier: self.draft.timeZoneID) ?? .current)
                Stepper(value: self.$draft.durationMinutes, in: 1 ... ScheduleWindow.maxDurationMinutes, step: 5) {
                    Text("Duration: \(self.draft.durationMinutes) min")
                }
                Stepper(value: self.$draft.leadMinutes, in: 0 ... 120, step: 1) {
                    Text("Wake in advance: \(self.draft.leadMinutes) min")
                }
                Picker("Repeat", selection: self.$draft.kind) {
                    Text("Never").tag(Recurrence.Kind.none)
                    Text("Every day").tag(Recurrence.Kind.daily)
                    Text("Weekly").tag(Recurrence.Kind.weekly)
                }
                if self.draft.kind == .weekly {
                    HStack {
                        ForEach(Weekday.allCases, id: \.self) { day in
                            Toggle(Self.shortName(day), isOn: Binding(
                                get: { self.draft.days.contains(day) },
                                set: { isOn in
                                    if isOn { self.draft.days.insert(day) } else { self.draft.days.remove(day) }
                                }
                            ))
                            .toggleStyle(.button)
                            .accessibilityLabel(Text(Self.longName(day)))
                        }
                    }
                }
                Toggle("Enabled", isOn: self.$draft.enabled)
            }
            if let errorText {
                Text(errorText).foregroundStyle(.red).accessibilityIdentifier("ScheduleEditor.error")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { self.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        try self.onSave(self.draft.makeWindow())
                        self.dismiss()
                    } catch {
                        self.errorText = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("ScheduleEditor.save")
            }
        }
        .padding()
        .frame(width: 440)
    }

    private static func symbols(_ day: Weekday, _ keyPath: KeyPath<Calendar, [String]>) -> String {
        Calendar.current[keyPath: keyPath][day.calendarValue - 1]
    }

    private static func shortName(_ day: Weekday) -> String { self.symbols(day, \.shortWeekdaySymbols) }
    private static func longName(_ day: Weekday) -> String { self.symbols(day, \.weekdaySymbols) }
}
