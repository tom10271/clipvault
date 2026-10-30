import SwiftUI
import AppKit
import ClipVaultCore

struct HistoryView: View {
    @ObservedObject var model: ClipboardController
    let openSettings: () -> Void
    @State private var search = ""
    @State private var trash = false
    @State private var deleteID: UUID?

    private var entries: [ClipboardEntry] {
        model.entries.filter { ($0.deletedAt != nil) == trash && model.matches($0, search: search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "lock.shield.fill").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ClipVault").font(.title3.weight(.semibold))
                    Text(model.isUnlocked ? "Encrypted on this Mac" : "Your clipboard, kept private").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.isUnlocked {
                    Button(action: openSettings) { Image(systemName: "gearshape") }.help("Settings").accessibilityLabel("Settings")
                    Button { model.lock() } label: { Image(systemName: "lock") }.help("Lock vault").accessibilityLabel("Lock vault")
                }
            }.buttonStyle(.borderless).padding(20)
            Divider()
            if model.isUnlocked { history } else { locked }
            if let message = model.message {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message).font(.caption).textSelection(.disabled)
                    Spacer(minLength: 0)
                    Button { model.dismissMessage() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("Dismiss message")
                }.padding(12).background(Color.orange.opacity(0.09))
            }
            Divider()
            HStack {
                Image(systemName: model.isCapturing ? "circle.fill" : "pause.circle").foregroundStyle(model.isCapturing ? Color.green : Color.secondary).font(.caption2)
                Text(model.isCapturing ? (model.isUnlocked ? "Listening for copied text" : "Listening · history locked") : "Capture paused").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.borderless).font(.caption)
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 460, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.revision) { _ in search = ""; deleteID = nil; trash = false }
        .onDisappear { model.hideSensitivePreviews() }
        .alert("Permanently delete this item?", isPresented: Binding(get: { deleteID != nil && model.isUnlocked }, set: { if !$0 { deleteID = nil } })) {
            Button("Cancel", role: .cancel) { deleteID = nil }
            Button("Delete permanently", role: .destructive) { if let id = deleteID { model.permanentlyDelete(id) }; deleteID = nil }
        } message: {
            Text("This removes the item from the current encrypted vault. It cannot erase copies in backups, SSD snapshots, other apps, or clipboard managers.")
        }
    }

    private var locked: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "lock.shield").font(.system(size: 56, weight: .light)).foregroundStyle(.tint)
            Text(model.isNew ? "A safer place for copied text" : "Your vault is locked").font(.title2.weight(.semibold))
            Text(model.isNew ? "Keep a local, encrypted history with Touch ID or your Mac login password. Start listening when you are ready." : "Unlock with Touch ID or your Mac login password to view your history. Enabled capture continues while locked.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).font(.callout).padding(.horizontal, 28)
            Button {
                Task { await model.unlock() }
            } label: {
                HStack { if model.isUnlocking { ProgressView().controlSize(.small) } else { Image(systemName: "touchid") }; Text(model.isUnlocking ? "Authenticating…" : model.isNew ? "Create encrypted vault" : "Unlock vault") }.frame(minWidth: 180)
            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.isUnlocking)
            if model.needsCaptureMigration { Text("Unlock once to enable encrypted capture while locked.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 28) }
            if model.isUnlocking { Button("Cancel") { model.lock() }.buttonStyle(.borderless) }
            Spacer()
            VStack(alignment: .leading, spacing: 9) {
                Label("AES-256-GCM encrypted history", systemImage: "checkmark.shield")
                Label("No cloud sync or network requests", systemImage: "network.slash")
                Label("New copies stay encrypted while history is locked", systemImage: "lock.doc")
            }.font(.caption).foregroundStyle(.secondary).padding(.bottom, 22)
        }.frame(maxWidth: .infinity)
    }

    private var history: some View {
        VStack(spacing: 12) {
            HStack {
                Picker("View", selection: $trash) { Text("History").tag(false); Text("Trash").tag(true) }.pickerStyle(.segmented).labelsHidden()
                Button { model.toggleCapture() } label: { Image(systemName: model.isCapturing ? "pause.fill" : "play.fill") }.help(model.isCapturing ? "Pause capture" : "Start listening").accessibilityLabel(model.isCapturing ? "Pause capture" : "Start listening")
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(trash ? "Search Trash" : "Search history", text: $search).textFieldStyle(.plain)
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).accessibilityLabel("Clear search") }
            }.padding(9).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            if entries.isEmpty {
                Spacer()
                Image(systemName: trash ? "trash" : "clipboard").font(.system(size: 38, weight: .light)).foregroundStyle(.secondary)
                Text(search.isEmpty ? (trash ? "Trash is empty" : "Your history starts here") : "No matching items").font(.headline)
                Text(search.isEmpty ? (trash ? "Deleted items can be restored here." : model.isCapturing ? "Copy some text in another app. Use Hide for sensitive values, and give them a name." : "Start listening, then copy text in another app.") : "Try a different search or an item name.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 24)
                if !trash && !model.isCapturing && search.isEmpty { Button("Start listening") { model.toggleCapture() }.buttonStyle(.borderedProminent) }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) { ForEach(entries) { entry in row(entry) } }
                }
            }
            HStack {
                Text("\(entries.count) \(trash ? "in Trash" : "items")").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Label("Locks in \(model.secondsRemaining)s", systemImage: "timer").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16)
    }

    private func row(_ entry: ClipboardEntry) -> some View {
        let visible = model.isValueVisible(entry)
        let revealSeconds = model.revealSecondsRemaining(entry)
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(entry.createdAt, style: .time).font(.caption2).foregroundStyle(.secondary)
                Text(entry.createdAt, style: .date).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(entry.isSensitive ? (revealSeconds > 0 ? "Hides in \(revealSeconds)s" : "Sensitive") : "\(entry.text.count) characters").font(.caption2).foregroundStyle(.secondary)
            }
            InlineItemName(entry: entry, model: model)
            Text(visible ? entry.text : "••••••••••••••••••••")
                .font(.system(.body, design: .monospaced)).lineLimit(visible ? 5 : 1).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(visible ? entry.text : "Hidden sensitive value")
            HStack(spacing: 12) {
                Button {
                    if !entry.isSensitive { model.setSensitive(entry.id, isSensitive: true) }
                    else if visible { model.hideValue(entry.id) }
                    else { model.revealValue(entry.id) }
                } label: { Label(visible ? "Hide" : "Show", systemImage: visible ? "eye.slash" : "eye") }
                    .help(entry.isSensitive && !visible ? "Show for 10 seconds" : "Mark sensitive and hide this value")
                    .accessibilityLabel(entry.isSensitive && !visible ? "Show for 10 seconds" : "Hide")
                if trash {
                    Button { model.restore(entry.id) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                } else {
                    Button { model.copy(entry.id) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    Button { model.softDelete(entry.id) } label: { Label("Trash", systemImage: "trash") }
                }
                Spacer(minLength: 0)
                if entry.isSensitive {
                    Menu { Button("Always show value") { model.setSensitive(entry.id, isSensitive: false) } }
                    label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize().help("Sensitivity options").accessibilityLabel("Sensitivity options")
                }
                Button(role: .destructive) { if model.interact() { deleteID = entry.id } } label: { Image(systemName: "trash.slash") }.help("Delete permanently").accessibilityLabel("Delete permanently")
            }.font(.caption).buttonStyle(.borderless)
        }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06)))
    }
}

private struct InlineItemName: View {
    let entry: ClipboardEntry
    @ObservedObject var model: ClipboardController
    @State private var draft: String
    @FocusState private var focused: Bool

    init(entry: ClipboardEntry, model: ClipboardController) {
        self.entry = entry
        self.model = model
        _draft = State(initialValue: entry.name ?? "")
    }

    var body: some View {
        TextField("Item name (optional)", text: $draft)
            .textFieldStyle(.roundedBorder).font(.headline)
            .accessibilityLabel("Item name")
            .focused($focused)
            .onSubmit { commit(); focused = false }
            .onChange(of: focused) { editing in
                if editing {
                    model.hideSensitivePreviews()
                    if !model.interact() { focused = false }
                } else { commit() }
            }
            .onChange(of: entry.name) { name in if !focused { draft = name ?? "" } }
            .onDisappear { commit() }
    }

    private func commit() {
        guard model.isUnlocked, let current = model.entries.first(where: { $0.id == entry.id }) else { return }
        guard draft != (current.name ?? "") else { return }
        model.rename(entry.id, name: draft)
        draft = model.entries.first(where: { $0.id == entry.id })?.name ?? current.name ?? ""
    }
}
