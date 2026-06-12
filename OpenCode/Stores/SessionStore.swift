//
//  SessionStore.swift
//  OpenCode
//
//  In-memory source of truth for sessions, messages, statuses, and pending
//  permissions. Hydrated via REST on every (re)connect, then kept current by
//  applying SSE events.
//

import Foundation
import Observation

@Observable
final class SessionStore {
    private(set) var sessions: [Session] = []
    private(set) var messagesBySession: [String: [MessageWithParts]] = [:]
    private(set) var statuses: [String: SessionStatus] = [:]
    private(set) var permissionsBySession: [String: [Permission]] = [:]

    private(set) var providers: [Provider] = []
    private(set) var defaultModels: [String: String] = [:]
    private(set) var agents: [Agent] = []

    /// Transient error surfaced as a banner; cleared automatically by the UI.
    var lastError: String?

    /// The session currently open in the chat view; its messages are
    /// refreshed on every re-sync.
    var activeSessionID: String?

    var selectedModel: ModelRef? {
        didSet {
            UserDefaults.standard.set(selectedModel?.providerID, forKey: "selectedProviderID")
            UserDefaults.standard.set(selectedModel?.modelID, forKey: "selectedModelID")
        }
    }

    var selectedAgent: String? {
        didSet {
            UserDefaults.standard.set(selectedAgent, forKey: "selectedAgent")
        }
    }

    private let connection: ServerConnection

    init(connection: ServerConnection) {
        self.connection = connection

        if
            let providerID = UserDefaults.standard.string(forKey: "selectedProviderID"),
            let modelID = UserDefaults.standard.string(forKey: "selectedModelID")
        {
            self.selectedModel = ModelRef(providerID: providerID, modelID: modelID)
        }
        self.selectedAgent = UserDefaults.standard.string(forKey: "selectedAgent")

        connection.onEvent = { [weak self] event in
            self?.apply(event)
        }
        connection.onConnected = { [weak self] in
            await self?.refreshAll()
        }
    }

    // MARK: - Derived state

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

    /// Flat list of selectable models for the picker.
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

    var selectableAgents: [Agent] {
        agents.filter(\.isSelectable)
    }

    // MARK: - Sync

    func refreshAll() async {
        guard let client = connection.client else { return }

        do {
            async let sessions = client.sessions()
            async let statuses = client.sessionStatuses()
            async let providers = client.providers()
            async let agents = client.agents()

            setSessions(try await sessions)
            self.statuses = try await statuses

            let providersResponse = try await providers
            self.providers = providersResponse.providers
            self.defaultModels = providersResponse.defaults
            self.agents = try await agents

            applyDefaultSelections()

            if let activeSessionID {
                await loadMessages(sessionID: activeSessionID)
            }
        } catch {
            report(error)
        }
    }

    func loadMessages(sessionID: String) async {
        guard let client = connection.client else { return }
        do {
            messagesBySession[sessionID] = try await client.messages(sessionID: sessionID)
        } catch {
            report(error)
        }
    }

    // MARK: - Actions

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
            remove(sessionID: session.id)
        } catch {
            report(error)
        }
    }

    /// Sends a prompt. Throws so the composer can keep the draft on failure.
    func send(text: String, sessionID: String) async throws {
        guard let client = connection.client else {
            throw APIError.http(status: 0, message: "Not connected")
        }
        do {
            try await client.prompt(
                sessionID: sessionID,
                request: PromptRequest(text: text, model: selectedModel, agent: selectedAgent)
            )
        } catch {
            report(error)
            throw error
        }
    }

    func abort(sessionID: String) async {
        guard let client = connection.client else { return }
        do {
            try await client.abort(sessionID: sessionID)
        } catch {
            report(error)
        }
    }

    func respond(to permission: Permission, with response: PermissionResponse) async {
        guard let client = connection.client else { return }
        do {
            try await client.respondToPermission(
                sessionID: permission.sessionID,
                permissionID: permission.id,
                response: response
            )
            removePermission(id: permission.id, sessionID: permission.sessionID)
        } catch {
            report(error)
        }
    }

    // MARK: - Event application

    func apply(_ event: ServerEvent) {
        switch event {
        case .serverConnected, .unknown:
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
            var permissions = permissionsBySession[permission.sessionID] ?? []
            if let index = permissions.firstIndex(where: { $0.id == permission.id }) {
                permissions[index] = permission
            } else {
                permissions.append(permission)
            }
            permissionsBySession[permission.sessionID] = permissions

        case .permissionReplied(let sessionID, let permissionID):
            removePermission(id: permissionID, sessionID: sessionID)
        }
    }

    // MARK: - Private helpers

    private func setSessions(_ newSessions: [Session]) {
        sessions = newSessions
            .filter { $0.parentID == nil }
            .sorted { ($0.timeUpdated ?? 0) > ($1.timeUpdated ?? 0) }
    }

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

    private func remove(sessionID: String) {
        sessions.removeAll { $0.id == sessionID }
        messagesBySession[sessionID] = nil
        permissionsBySession[sessionID] = nil
        statuses[sessionID] = nil
    }

    private func upsert(messageInfo info: MessageInfo) {
        var messages = messagesBySession[info.sessionID] ?? []
        if let index = messages.firstIndex(where: { $0.id == info.id }) {
            messages[index].info = info
        } else {
            messages.append(MessageWithParts(info: info, parts: []))
        }
        messagesBySession[info.sessionID] = messages
    }

    private func upsert(part: Part) {
        var messages = messagesBySession[part.sessionID] ?? []

        let messageIndex: Int
        if let index = messages.firstIndex(where: { $0.id == part.messageID }) {
            messageIndex = index
        } else {
            // Part arrived before its message: create a placeholder; the
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

    private func applyDefaultSelections() {
        let allModels = availableModels

        let selectionIsValid = selectedModel.map { selected in
            allModels.contains { $0.ref == selected }
        } ?? false

        if !selectionIsValid {
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
            selectedAgent = selectableAgents.first { $0.name == "build" }?.name
                ?? selectableAgents.first?.name
        }
    }

    private func report(_ error: Error) {
        if error is CancellationError { return }
        if let urlError = error as? URLError, urlError.code == .cancelled { return }
        lastError = error.localizedDescription
    }
}
