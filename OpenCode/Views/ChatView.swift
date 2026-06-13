//
//  ChatView.swift
//  OpenCode
//
//  The conversation: streamed messages, pending permission cards, the
//  composer, and the chat settings menu (model/agent selection) in the
//  toolbar. Message loading is selection-driven (see ContentView); this
//  view only renders store state and re-syncs live via SSE events.
//
//  Rendering is driven entirely by the store — this view holds no message
//  state of its own. Streaming updates (parts growing token by token)
//  arrive as store mutations and re-render the affected rows.
//

import SwiftUI

struct ChatView: View {
    @Environment(ServerConnection.self) private var connection
    @Environment(SessionStore.self) private var store

    let session: Session

    /// Drives the Todos bottom sheet presented from the chat settings menu.
    /// Local to ChatView (per-session, ephemeral) — `.id(session.id)` on
    /// the parent guarantees this resets when the user switches sessions.
    @State private var showingTodos = false

    /// Drives the rename alert presented from the chat settings menu. The
    /// draft is seeded from the current title when the alert opens, so a
    /// small edit is one keystroke away.
    @State private var isRenaming = false
    @State private var renameDraft = ""

    var body: some View {
        ScrollView {
            // Lazy: histories can be long and tool outputs heavy; only
            // visible rows are materialized.
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(store.messages(for: session.id)) { message in
                    MessageView(message: message)
                }
                // Pending permissions render at the end of the transcript —
                // chronologically that is where the agent is blocked.
                ForEach(store.permissions(for: session.id)) { permission in
                    PermissionCard(permission: permission)
                }
            }
            .padding()
        }
        // Chat-style scrolling: start at the bottom (newest content).
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(session.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // One trailing slot, two occupants: while the agent works it
            // shows the spinner, otherwise the chat settings menu (model
            // and agent selection for new prompts).
            ToolbarItem(placement: .topBarTrailing) {
                if store.status(for: session.id).isWorking {
                    ProgressView()
                } else {
                    chatSettingsMenu
                }
            }
        }
        // The composer sits in the bottom safe-area inset so the scroll
        // content is never hidden behind it.
        .safeAreaInset(edge: .bottom) {
            ComposerView(session: session)
        }
        // Bottom-sheet view of the agent's current todo list. Data is
        // already in the store by the time this presents (loaded on
        // session selection in ContentView); SSE keeps it live while open.
        .sheet(isPresented: $showingTodos) {
            TodoListSheet(sessionID: session.id)
        }
        // Rename alert: a single TextField inside a native alert. Closes
        // unconditionally on Save/Cancel — failures surface via the
        // store's error banner, matching the rest of the store actions.
        .alert("Rename Session", isPresented: $isRenaming) {
            TextField("Title", text: $renameDraft)
                .textInputAutocapitalization(.sentences)
            Button("Save") { commitRename() }
                .disabled(!isRenameDraftValid)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a new title for this session.")
        }
        // Note: message loading is intentionally NOT triggered here.
        // ContentView drives it from the sidebar selection — a `.task` on
        // this view gets cancelled (and never restarted) by the spurious
        // disappear/appear cycle NavigationSplitView produces during push
        // transitions on iPhone.
    }

    /// Per-chat settings menu, split by a single Divider:
    ///   • Above: model + agent used for *new* prompts (configure).
    ///   • Below: actions and views scoped to *this* session — Rename
    ///     (mutate the title) and Todos (read the agent's current plan).
    private var chatSettingsMenu: some View {
        @Bindable var store = store
        return Menu {
            Picker("Model", selection: $store.selectedModel) {
                ForEach(store.availableModels, id: \.ref) { model in
                    Text(model.displayName).tag(model.ref as ModelRef?)
                }
            }
            .pickerStyle(.menu)

            Picker("Agent", selection: $store.selectedAgent) {
                ForEach(store.selectableAgents) { agent in
                    Text(agent.name).tag(agent.name as String?)
                }
            }
            .pickerStyle(.menu)

            Divider()

            // Mutates this session (PATCHes the title); seeds the alert
            // draft so the existing title is one backspace away from
            // being edited.
            Button {
                renameDraft = session.title
                isRenaming = true
            } label: {
                Label("Rename Session", systemImage: "pencil")
            }

            // Always visible — tapping with an empty list shows the
            // "no plan yet" placeholder, which is itself useful feedback.
            Button {
                showingTodos = true
            } label: {
                Label("Todos", systemImage: "checklist")
            }
        } label: {
            Label("Chat Settings", systemImage: "gearshape")
        }
        // Both picker lists are empty until the first successful
        // providers/agents fetch — but the Todos button works without
        // either, so we only disable on the truly-empty initial state.
        .disabled(store.availableModels.isEmpty && store.selectableAgents.isEmpty)
    }

    /// `true` when the draft is non-empty (after trimming whitespace) and
    /// genuinely different from the current title — Save is pointless
    /// otherwise. Mirrored on the alert's Save button.
    private var isRenameDraftValid: Bool {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != session.title
    }

    /// Fires the rename. The alert is already dismissed by the time this
    /// runs (SwiftUI closes the alert before invoking the button action);
    /// errors surface via the store's error banner.
    private func commitRename() {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != session.title else { return }
        Task {
            await store.renameSession(session, to: trimmed)
        }
    }
}

// MARK: - Permission card

/// Inline approval prompt rendered in the transcript. Shows what the agent
/// wants to do (title + patterns) right where the user is already reading,
/// with the three replies the server accepts.
struct PermissionCard: View {
    @Environment(SessionStore.self) private var store

    let permission: Permission

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Permission Required", systemImage: "lock.shield.fill")
                .font(.subheadline.bold())
                .foregroundStyle(.orange)

            // Title when the server sends one, else the permission category
            // (e.g. "external_directory").
            Text(permission.displayTitle)
                .font(.callout)

            // What exactly the agent wants to touch (file path, command…).
            if let detail = permission.detail {
                Text(detail)
                    .font(.caption.monospaced())
                    .lineLimit(3)
            }

            // The pattern(s) an "Always Allow" would whitelist — the user
            // should see the scope before granting it permanently.
            if !permission.patterns.isEmpty {
                Text("Always allows: " + permission.patterns.joined(separator: ", "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack {
                Button("Deny", role: .destructive) {
                    respond(.reject)
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Always Allow") {
                    respond(.always)
                }
                .buttonStyle(.bordered)

                // "Allow Once" is the prominent default action.
                Button("Allow Once") {
                    respond(.once)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.orange.opacity(0.4))
        )
    }

    private func respond(_ response: PermissionResponse) {
        Task {
            await store.respond(to: permission, with: response)
        }
    }
}
