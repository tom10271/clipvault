import SwiftUI
import ClipVaultCore

struct SettingsRoot: View {
    @ObservedObject var model: ClipboardController
    var body: some View {
        Group {
            if model.isUnlocked { SettingsView(model: model, draft: model.settings).id(model.revision) }
            else {
                VStack(spacing: 18) {
                    Image(systemName: "lock.shield").font(.largeTitle).foregroundStyle(.tint)
                    Text("Settings are locked").font(.title2)
                    Text("Unlock your vault to change its settings.").foregroundStyle(.secondary)
                    Button("Unlock vault") { Task { await model.unlock() } }.buttonStyle(.borderedProminent).disabled(model.isUnlocking)
                    if let message = model.message { Text(message).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center) }
                }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(width: 540, height: 590)
    }
}

private struct SettingsView: View {
    @ObservedObject var model: ClipboardController
    @State var draft: VaultSettings
    @State private var unit = 1.0
    @State private var excludedText = ""
    @State private var saved = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings").font(.title2.weight(.semibold))
                    Text("Make privacy fit your workflow.").foregroundStyle(.secondary).font(.callout)
                }
                Spacer()
                Image(systemName: "slider.horizontal.3").font(.title2).foregroundStyle(.tint)
            }.padding(24)
            Form {
                Section("Security") {
                    HStack {
                        Text("Auto-lock after inactivity")
                        Spacer()
                        TextField("Duration", value: Binding(get: { draft.autoLockSeconds / unit }, set: { draft.autoLockSeconds = $0 * unit }), format: .number).labelsHidden().frame(width: 65)
                        Picker("Unit", selection: $unit) { Text("seconds").tag(1.0); Text("minutes").tag(60.0) }.labelsHidden().frame(width: 100)
                    }
                    Text("Touch ID or your Mac login password is required to unlock. Only activity inside ClipVault extends this timer. Sleep and screen lock lock it immediately.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("Clear copied history text after")
                        Spacer()
                        TextField("Seconds", value: $draft.clipboardClearSeconds, format: .number).labelsHidden().frame(width: 65)
                        Text("seconds").foregroundStyle(.secondary)
                    }
                    Text("Clears only content ClipVault copied, if no newer clipboard content replaced it. Locking also clears that content.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Capture") {
                    Toggle("Listen for copied text, including while locked", isOn: $draft.captureEnabled)
                    Toggle("Skip content marked private or temporary", isOn: $draft.ignoreConcealed)
                    Text("Password managers often mark sensitive text private. Keep this enabled to skip it. Locking protects history access; listening continues.").font(.caption).foregroundStyle(.secondary)
                    TextField("Excluded app bundle IDs, one per line", text: $excludedText, axis: .vertical).lineLimit(3...4)
                    Text("For example, com.apple.Terminal. Exclusions use the app in front when the clipboard change is observed.").font(.caption).foregroundStyle(.secondary)
                }
                Section("History and Trash") {
                    HStack { Text("Maximum items, including Trash"); Spacer(); TextField("Items", value: $draft.historyLimit, format: .number).labelsHidden().frame(width: 75) }
                    HStack { Text("Permanently expire items after"); Spacer(); TextField("Days", value: $draft.retentionDays, format: .number).labelsHidden().frame(width: 65); Text("days").foregroundStyle(.secondary) }
                    Text("Limits apply on capture, unlock, and settings changes. Older items, including Trash, are permanently removed from the current vault. Backups may retain copies.").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.red).padding(.horizontal, 24).padding(.bottom, 10) }
            Divider()
            HStack {
                if saved { Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption) }
                Spacer()
                Button("Lock now") { model.lock() }
                Button("Save settings") {
                    draft.excludedApps = excludedText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    model.dismissMessage()
                    model.saveSettings(draft)
                    saved = model.message == nil && model.isUnlocked
                }.buttonStyle(.borderedProminent)
            }.padding(18)
        }
        .onAppear { excludedText = draft.excludedApps.joined(separator: "\n"); if draft.autoLockSeconds.truncatingRemainder(dividingBy: 60) == 0 { unit = 60 } }
        .onChange(of: draft) { _ in saved = false }
        .onChange(of: excludedText) { _ in saved = false }
    }
}
