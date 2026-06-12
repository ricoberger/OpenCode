//
//  SessionListView.swift
//  OpenCode
//
//  Sidebar: root sessions sorted by last update, connection status bar,
//  new-session and settings buttons, swipe-to-delete with confirmation.
//

import SwiftUI

struct SessionListView: View {
    @Environment(ServerConnection.self) private var connection
    @Environment(SessionStore.self) private var store

    @Binding var selectedSessionID: String?
    @Binding var showSettings: Bool

    @State private var sessionToDelete: Session?

    var body: some View {
        List(selection: $selectedSessionID) {
            ForEach(store.rootSessions) { session in
                SessionRow(
                    session: session,
                    isWorking: store.status(for: session.id).isWorking,
                    hasPendingPermission: !store.permissions(for: session.id).isEmpty
                )
                .tag(session.id)
                .swipeActions(edge: .trailing) {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        sessionToDelete = session
                    }
                }
            }
        }
        .navigationTitle("Sessions")
        .overlay { emptyState }
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
        .safeAreaInset(edge: .bottom) {
            ConnectionStatusBar()
        }
        .refreshable {
            await store.refreshAll()
        }
        .confirmationDialog(
            "Delete Session?",
            isPresented: Binding(
                get: { sessionToDelete != nil },
                set: { if !$0 { sessionToDelete = nil } }
            ),
            presenting: sessionToDelete
        ) { session in
            Button("Delete \"\(session.displayTitle)\"", role: .destructive) {
                Task {
                    if selectedSessionID == session.id {
                        selectedSessionID = nil
                    }
                    await store.deleteSession(session)
                }
            }
        } message: { _ in
            Text("This permanently deletes the session and all its messages.")
        }
    }

    private func createSession() {
        Task {
            if let session = await store.createSession() {
                selectedSessionID = session.id
            }
        }
    }

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
        case .connected where store.rootSessions.isEmpty:
            ContentUnavailableView {
                Label("No Sessions", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Create a session to start working with opencode.")
            } actions: {
                Button("New Session") { createSession() }
                    .buttonStyle(.borderedProminent)
            }
        default:
            EmptyView()
        }
    }
}

// MARK: - Row

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
                    Text(updatedAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

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

// MARK: - Connection status

private struct ConnectionStatusBar: View {
    @Environment(ServerConnection.self) private var connection

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var color: Color {
        switch connection.state {
        case .connected: .green
        case .connecting: .yellow
        case .disconnected: .red
        case .unconfigured: .gray
        }
    }

    private var label: String {
        switch connection.state {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .disconnected: "Disconnected"
        case .unconfigured: "Not configured"
        }
    }
}
