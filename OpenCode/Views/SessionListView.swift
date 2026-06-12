//
//  SessionListView.swift
//  OpenCode
//
//  Sidebar: root sessions sorted by last update, new-session and settings
//  buttons, swipe-to-delete.
//
//  Empty states double as onboarding: unconfigured → "Set Up Server",
//  disconnected → error + retry, connected-but-empty → "New Session".
//

import SwiftUI

struct SessionListView: View {
    @Environment(ServerConnection.self) private var connection
    @Environment(SessionStore.self) private var store

    @Binding var selectedSessionID: String?
    @Binding var showSettings: Bool

    var body: some View {
        Group {
            // Empty state and list are mutually exclusive: when a
            // full-screen state applies, the session rows are not shown
            // (even if stale sessions are still in memory).
            if showsEmptyState {
                emptyState
            } else {
                sessionList
            }
        }
        .navigationTitle("Sessions")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Settings", systemImage: "gearshape") {
                    showSettings = true
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("New Session", systemImage: "plus") {
                    createSession()
                }
                .disabled(!connection.state.isConnected)
            }
        }
    }

    private var sessionList: some View {
        List(selection: $selectedSessionID) {
            ForEach(store.rootSessions) { session in
                SessionRow(
                    session: session,
                    isWorking: store.status(for: session.id).isWorking,
                    hasPendingPermission: !store.permissions(for: session.id).isEmpty
                )
                // Tag by ID to match the selection binding's type.
                .tag(session.id)
                .swipeActions(edge: .trailing) {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        deleteSession(session)
                    }
                }
            }
        }
        // Manual re-sync escape hatch (the same full refresh that runs on
        // every reconnect).
        .refreshable {
            await store.refreshAll()
        }
    }

    /// Whether a full-screen state replaces the list. While connecting,
    /// an already-loaded list stays visible (brief reconnects after
    /// foregrounding should not blank the sidebar).
    private var showsEmptyState: Bool {
        switch connection.state {
        case .unconfigured, .disconnected:
            return true
        case .connecting, .connected:
            return store.rootSessions.isEmpty
        }
    }

    /// Deletes immediately — no confirmation by design.
    private func deleteSession(_ session: Session) {
        Task {
            // Clear the selection first so the detail column does not
            // briefly show a deleted session.
            if selectedSessionID == session.id {
                selectedSessionID = nil
            }
            await store.deleteSession(session)
        }
    }

    /// Creates a session and navigates straight into it.
    private func createSession() {
        Task {
            if let session = await store.createSession() {
                selectedSessionID = session.id
            }
        }
    }

    /// Full-screen state shown instead of the list. Which one shows is
    /// driven by the connection state machine.
    @ViewBuilder
    private var emptyState: some View {
        switch connection.state {
        case .unconfigured:
            ContentUnavailableView {
                Label("No Server Configured", systemImage: "server.rack")
            } description: {
                Text("Start `opencode serve --hostname 0.0.0.0` on your computer, then add its address here.")
            } actions: {
                Button("Set Up Server") { showSettings = true }
                    .buttonStyle(.borderedProminent)
            }
        case .disconnected(let reason):
            ContentUnavailableView {
                Label("Disconnected", systemImage: "wifi.exclamationmark")
            } description: {
                Text(reason ?? "The server is not reachable.")
            } actions: {
                Button("Retry") { connection.connect() }
                    .buttonStyle(.borderedProminent)
            }
        case .connecting:
            // Initial connect with nothing loaded yet.
            ProgressView("Connecting…")
        case .connected:
            // Only reachable when the session list is empty (see
            // showsEmptyState).
            ContentUnavailableView {
                Label("No Sessions", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Create a session to start working with opencode.")
            } actions: {
                Button("New Session") { createSession() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Row

/// One sidebar entry: title, relative update time, and up to two trailing
/// indicators (pending permission, agent working).
private struct SessionRow: View {
    let session: Session
    let isWorking: Bool
    let hasPendingPermission: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle)
                    .lineLimit(2)
                if let updatedAt = session.updatedAt {
                    // "5 minutes ago" style; updates on re-render.
                    Text(updatedAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Orange shield = the agent is blocked waiting for the user.
            // Most important signal in the list, so it comes first.
            if hasPendingPermission {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.orange)
            }
            if isWorking {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
}
