//
//  SessionStore.swift
//  OpenCode
//
//  In-memory source of truth for sessions, messages, statuses, and pending
//  permissions. There is no local persistence by design: the server owns
//  the data, the app is a remote control.
//
//  Data flows in twice:
//  1. Bulk: `refreshAll()` hydrates everything via REST. Runs on every
//     (re)connect because SSE has no replay — see ServerConnection.
//  2. Incremental: `apply(_:)` folds individual SSE events into the state.
//
//  Both paths are written to be idempotent (upserts keyed by id), so a
//  re-sync racing an event stream cannot duplicate or corrupt state.
//
//  All user actions (send/abort/create/delete/respond) also live here so
//  views stay free of API calls.
//

import Foundation
import Observation

@Observable
final class SessionStore {
    // MARK: - Observable state

    /// Root sessions, sorted by `timeUpdated` descending (sidebar order).
    /// Child (subagent) sessions are filtered out on the way in.
    private(set) var sessions: [Session] = []
    /// Message history per session ID. Only sessions the user has opened
    /// are populated; entries update live via SSE part/message events.
    private(set) var messagesBySession: [String: [MessageWithParts]] = [:]
    /// Working/idle state per session ID; missing entry means idle.
    private(set) var statuses: [String: SessionStatus] = [:]
    /// Pending (unanswered) permission requests per session ID.
    private(set) var permissionsBySession: [String: [Permission]] = [:]
    /// Current todo list per session ID. Lazy-populated: only sessions the
    /// user has opened have an entry. Server delivers full-list snapshots
    /// (both REST and SSE), so updates replace the array wholesale.
    private(set) var todosBySession: [String: [TodoItem]] = [:]

    private(set) var providers: [Provider] = []
    /// Server default model per provider (providerID → modelID).
    private(set) var defaultModels: [String: String] = [:]
    private(set) var agents: [Agent] = []
    /// Server-wide list of skills (instruction sets the agent can load).
    /// Hydrated by `refreshAll` and never patched live — the server does
    /// not emit skill-change events, so a reconnect re-fetches.
    private(set) var skills: [Skill] = []

    /// Transient error surfaced as a banner; cleared automatically by the UI.
    var lastError: String?

    /// The session currently open in the chat view; its messages are
    /// refreshed on every re-sync so a backgrounded chat catches up.
    var activeSessionID: String?

    /// The model used for new prompts. App-wide (not per-session) by
    /// design; persisted across launches.
    var selectedModel: ModelRef? {
        didSet {
            UserDefaults.standard.set(selectedModel?.providerID, forKey: "selectedProviderID")
            UserDefaults.standard.set(selectedModel?.modelID, forKey: "selectedModelID")
        }
    }

    /// The agent used for new prompts. Same persistence rules as the model.
    var selectedAgent: String? {
        didSet {
            UserDefaults.standard.set(selectedAgent, forKey: "selectedAgent")
        }
    }

    private let connection: ServerConnection

    init(connection: ServerConnection) {
        self.connection = connection

        // Restore the last-used model/agent; validated against the server's
        // actual lists once `refreshAll()` has run (applyDefaultSelections).
        if
            let providerID = UserDefaults.standard.string(forKey: "selectedProviderID"),
            let modelID = UserDefaults.standard.string(forKey: "selectedModelID")
        {
            self.selectedModel = ModelRef(providerID: providerID, modelID: modelID)
        }
        self.selectedAgent = UserDefaults.standard.string(forKey: "selectedAgent")

        // Wire up the connection: incremental events flow into `apply`,
        // and every (re)connect triggers a full re-sync.
        connection.onEvent = { [weak self] event in
            self?.apply(event)
        }
        connection.onConnected = { [weak self] in
            await self?.refreshAll()
        }
    }

    // MARK: - Derived state (view-facing accessors)

    var rootSessions: [Session] {
        sessions
    }

    func messages(for sessionID: String) -> [MessageWithParts] {
        messagesBySession[sessionID] ?? []
    }

    func status(for sessionID: String) -> SessionStatus {
        statuses[sessionID] ?? .idle
    }

    func permissions(for sessionID: String) -> [Permission] {
        permissionsBySession[sessionID] ?? []
    }

    func todos(for sessionID: String) -> [TodoItem] {
        todosBySession[sessionID] ?? []
    }

    /// Flat list of selectable models for the picker, sorted by provider
    /// then model name for a stable menu.
    var availableModels: [(ref: ModelRef, displayName: String)] {
        providers
            .sorted { $0.name < $1.name }
            .flatMap { provider in
                provider.models
                    .map { key, model in
                        (
                            ref: ModelRef(providerID: provider.id, modelID: model.id ?? key),
                            displayName: "\(model.name ?? key)"
                        )
                    }
                    .sorted { $0.displayName < $1.displayName }
            }
    }

    /// Agents the user may pick (subagent-only agents are excluded).
    var selectableAgents: [Agent] {
        agents.filter(\.isSelectable)
    }

    // MARK: - Sync

    /// Full state hydration via REST. Called on every (re)connect, and by
    /// pull-to-refresh. The four fetches run concurrently.
    func refreshAll() async {
        guard let client = connection.client else { return }

        do {
            async let sessions = client.sessions()
            async let statuses = client.sessionStatuses()
            async let providers = client.providers()
            async let agents = client.agents()
            async let skills = client.skills()

            setSessions(try await sessions)
            self.statuses = try await statuses

            let providersResponse = try await providers
            self.providers = providersResponse.providers
            self.defaultModels = providersResponse.defaults
            self.agents = try await agents
            self.skills = try await skills

            // Now that the real model/agent lists are known, make sure the
            // remembered selection still exists (or pick sane defaults).
            applyDefaultSelections()

            // Re-fetch the open conversation; its messages may have changed
            // while we were disconnected.
            if let activeSessionID {
                await loadMessages(sessionID: activeSessionID)
                await loadTodos(sessionID: activeSessionID)
            }
        } catch {
            report(error)
        }
    }

    /// Loads (or reloads) the full message history of one session,
    /// replacing whatever was cached for it.
    func loadMessages(sessionID: String) async {
        guard let client = connection.client else { return }
        do {
            messagesBySession[sessionID] = try await client.messages(sessionID: sessionID)
        } catch {
            report(error)
        }
    }

    /// Loads (or reloads) the current todo list for one session. Called
    /// alongside `loadMessages` on session selection so the Todos sheet
    /// opens with data already present; SSE `todo.updated` events keep
    /// it current while the user is viewing it.
    func loadTodos(sessionID: String) async {
        guard let client = connection.client else { return }
        do {
            todosBySession[sessionID] = try await client.todos(sessionID: sessionID)
        } catch {
            report(error)
        }
    }

    // MARK: - Actions

    /// Creates a session and returns it so the caller can navigate into it.
    /// The session is inserted optimistically; the `session.created` event
    /// that follows is a harmless idempotent upsert.
    func createSession() async -> Session? {
        guard let client = connection.client else { return nil }
        do {
            let session = try await client.createSession()
            upsert(session: session)
            return session
        } catch {
            report(error)
            return nil
        }
    }

    func deleteSession(_ session: Session) async {
        guard let client = connection.client else { return }
        do {
            try await client.deleteSession(id: session.id)
            // Remove locally right away instead of waiting for the
            // session.deleted event, so the row disappears immediately.
            remove(sessionID: session.id)
        } catch {
            report(error)
        }
    }

    /// Renames a session via `PATCH /session/:id`. Applies the server's
    /// echoed session right away so the title bar and sidebar update
    /// without waiting for the `session.updated` SSE event that follows
    /// (the event is then a harmless idempotent upsert). Errors funnel
    /// through the banner — the rename alert closes regardless, matching
    /// the rest of the store's fire-and-forget action style.
    func renameSession(_ session: Session, to newTitle: String) async {
        guard let client = connection.client else { return }
        do {
            let updated = try await client.updateSession(id: session.id, title: newTitle)
            upsert(session: updated)
        } catch {
            report(error)
        }
    }

    /// Sends a prompt with zero or more inline file attachments. Throws so
    /// the composer can keep the draft (and attachments) on failure — they
    /// are only cleared after the server accepted the prompt. No
    /// optimistic message insert: the `message.updated` event arrives
    /// within milliseconds on a healthy connection.
    ///
    /// `attachments` are already encoded (resized, base64'd, wrapped in a
    /// `data:` URL) by the composer; the store stays oblivious to image
    /// formats and just hands the parts through.
    func send(
        text: String,
        attachments: [PromptRequest.PartInput] = [],
        sessionID: String
    ) async throws {
        guard let client = connection.client else {
            throw APIError.http(status: 0, message: "Not connected")
        }
        do {
            try await client.prompt(
                sessionID: sessionID,
                request: PromptRequest(
                    text: text,
                    attachments: attachments,
                    model: selectedModel,
                    agent: selectedAgent
                )
            )
        } catch {
            report(error)
            throw error
        }
    }

    /// Stops the running agent turn. The resulting status flip ("idle")
    /// arrives via SSE; nothing to update locally.
    func abort(sessionID: String) async {
        guard let client = connection.client else { return }
        do {
            try await client.abort(sessionID: sessionID)
        } catch {
            report(error)
        }
    }

    /// Answers a permission request (the agent is blocked until then).
    func respond(to permission: Permission, with response: PermissionResponse) async {
        guard let client = connection.client else { return }
        do {
            try await client.respondToPermission(
                sessionID: permission.sessionID,
                permissionID: permission.id,
                response: response
            )
            // Remove locally right away; the permission.replied event that
            // follows is a no-op then.
            removePermission(id: permission.id, sessionID: permission.sessionID)
        } catch {
            report(error)
        }
    }

    // MARK: - Event application

    /// Folds one SSE event into the in-memory state. Pure state transition
    /// (no I/O), which is what makes it unit-testable with scripted events.
    func apply(_ event: ServerEvent) {
        switch event {
        case .serverConnected, .unknown:
            // serverConnected is handled by ServerConnection (re-sync);
            // unknown events are deliberately dropped.
            break

        case .sessionCreated(let session), .sessionUpdated(let session):
            upsert(session: session)

        case .sessionDeleted(let session):
            remove(sessionID: session.id)

        case .sessionStatus(let sessionID, let status):
            statuses[sessionID] = status

        case .sessionIdle(let sessionID):
            statuses[sessionID] = .idle

        case .sessionError(_, let error):
            // Aborts are user-initiated (stop button) — not worth a banner.
            if let error, !error.isAbort {
                lastError = error.displayMessage
            }

        case .messageUpdated(let info):
            upsert(messageInfo: info)

        case .messageRemoved(let sessionID, let messageID):
            messagesBySession[sessionID]?.removeAll { $0.id == messageID }

        case .partUpdated(let part):
            upsert(part: part)

        case .partRemoved(let sessionID, let messageID, let partID):
            guard var messages = messagesBySession[sessionID],
                  let index = messages.firstIndex(where: { $0.id == messageID })
            else { return }
            messages[index].parts.removeAll { $0.id == partID }
            messagesBySession[sessionID] = messages

        case .permissionUpdated(let permission):
            // Upsert by id: the server may re-emit the same permission with
            // updated details; it must not appear twice.
            var permissions = permissionsBySession[permission.sessionID] ?? []
            if let index = permissions.firstIndex(where: { $0.id == permission.id }) {
                permissions[index] = permission
            } else {
                permissions.append(permission)
            }
            permissionsBySession[permission.sessionID] = permissions

        case .permissionReplied(let sessionID, let permissionID):
            // Covers replies from this client *and* from other clients
            // (e.g. the user answered in the TUI on their Mac).
            removePermission(id: permissionID, sessionID: sessionID)

        case .todoUpdated(let sessionID, let todos):
            // Server-side semantics are full replacement: the event
            // carries the entire current list, not a delta.
            todosBySession[sessionID] = todos
        }
    }

    // MARK: - Private helpers

    /// Replaces the session list (bulk sync path): drops subagent children
    /// and sorts newest-updated first.
    private func setSessions(_ newSessions: [Session]) {
        sessions = newSessions
            .filter { $0.parentID == nil }
            .sorted { ($0.timeUpdated ?? 0) > ($1.timeUpdated ?? 0) }
    }

    /// Inserts or updates a single session (event path), keeping the sort
    /// order intact. Child sessions are ignored entirely.
    private func upsert(session: Session) {
        guard session.parentID == nil else { return }
        var updated = sessions
        if let index = updated.firstIndex(where: { $0.id == session.id }) {
            updated[index] = session
        } else {
            updated.append(session)
        }
        sessions = updated.sorted { ($0.timeUpdated ?? 0) > ($1.timeUpdated ?? 0) }
    }

    /// Removes a session and all state tied to it.
    private func remove(sessionID: String) {
        sessions.removeAll { $0.id == sessionID }
        messagesBySession[sessionID] = nil
        permissionsBySession[sessionID] = nil
        todosBySession[sessionID] = nil
        statuses[sessionID] = nil
    }

    /// Inserts a new message or updates an existing one's metadata.
    /// Crucially, updating metadata must *not* touch `parts` — part state
    /// is owned by the part events.
    private func upsert(messageInfo info: MessageInfo) {
        var messages = messagesBySession[info.sessionID] ?? []
        if let index = messages.firstIndex(where: { $0.id == info.id }) {
            messages[index].info = info
        } else {
            messages.append(MessageWithParts(info: info, parts: []))
        }
        messagesBySession[info.sessionID] = messages
    }

    /// Inserts or replaces a part within its message. Parts stream
    /// repeatedly with growing content (e.g. text accumulating), so
    /// replace-by-id is the common case.
    private func upsert(part: Part) {
        var messages = messagesBySession[part.sessionID] ?? []

        let messageIndex: Int
        if let index = messages.firstIndex(where: { $0.id == part.messageID }) {
            messageIndex = index
        } else {
            // Part arrived before its message (SSE makes no ordering
            // promises across event types): create a placeholder; the
            // message.updated event will fill in the real info.
            let placeholder = MessageInfo(id: part.messageID, sessionID: part.sessionID, role: .assistant)
            messages.append(MessageWithParts(info: placeholder, parts: []))
            messageIndex = messages.count - 1
        }

        if let partIndex = messages[messageIndex].parts.firstIndex(where: { $0.id == part.id }) {
            messages[messageIndex].parts[partIndex] = part
        } else {
            messages[messageIndex].parts.append(part)
        }
        messagesBySession[part.sessionID] = messages
    }

    private func removePermission(id: String, sessionID: String) {
        permissionsBySession[sessionID]?.removeAll { $0.id == id }
    }

    /// Ensures the selected model/agent actually exist on the server,
    /// falling back to the server's defaults. Runs after every re-sync, so
    /// switching servers (or a server losing a provider) self-heals.
    private func applyDefaultSelections() {
        let allModels = availableModels

        let selectionIsValid = selectedModel.map { selected in
            allModels.contains { $0.ref == selected }
        } ?? false

        if !selectionIsValid {
            // Prefer the server's declared default; the sorted-first key
            // just makes the choice deterministic when there are several.
            if
                let providerID = defaultModels.keys.sorted().first,
                let modelID = defaultModels[providerID]
            {
                selectedModel = ModelRef(providerID: providerID, modelID: modelID)
            } else {
                selectedModel = allModels.first?.ref
            }
        }

        let agentIsValid = selectedAgent.map { selected in
            selectableAgents.contains { $0.name == selected }
        } ?? false

        if !agentIsValid {
            // "build" is opencode's standard default agent.
            selectedAgent = selectableAgents.first { $0.name == "build" }?.name
                ?? selectableAgents.first?.name
        }
    }

    /// Funnels action/sync errors into the banner, dropping cancellations
    /// (those are lifecycle noise, not user-relevant failures).
    private func report(_ error: Error) {
        if error is CancellationError { return }
        if let urlError = error as? URLError, urlError.code == .cancelled { return }
        lastError = error.localizedDescription
    }
}
