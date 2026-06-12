//
//  ChatView.swift
//  OpenCode
//
//  The conversation: streamed messages, pending permission cards, and the
//  composer. Messages load on appear and re-sync via the session store.
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
            // Subtle "agent is working" indicator in the chat header.
            if store.status(for: session.id).isWorking {
                ToolbarItem(placement: .topBarTrailing) {
                    ProgressView()
                }
            }
        }
        // The composer sits in the bottom safe-area inset so the scroll
        // content is never hidden behind it.
        .safeAreaInset(edge: .bottom) {
            ComposerView(session: session)
        }
        // Keyed by session ID: switching sessions cancels the old load and
        // starts a fresh one. Also registers this session as "active" so
        // refreshAll() reloads its messages after reconnects.
        .task(id: session.id) {
            store.activeSessionID = session.id
            await store.loadMessages(sessionID: session.id)
        }
        .onDisappear {
            // Only clear if we are still the active session — on iPhone a
            // push/pop can interleave appear/disappear between two chats.
            if store.activeSessionID == session.id {
                store.activeSessionID = nil
            }
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

            if !permission.title.isEmpty {
                Text(permission.title)
                    .font(.callout)
            }

            // The pattern(s) an "Always Allow" would whitelist — the user
            // should see the scope before granting it permanently.
            if !permission.patterns.isEmpty {
                Text(permission.patterns.joined(separator: ", "))
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
