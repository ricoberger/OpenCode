//
//  ChatView.swift
//  OpenCode
//
//  The conversation: streamed messages, pending permission cards, and the
//  composer. Messages load on appear and re-sync via the session store.
//

import SwiftUI

struct ChatView: View {
    @Environment(ServerConnection.self) private var connection
    @Environment(SessionStore.self) private var store

    let session: Session

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(store.messages(for: session.id)) { message in
                    MessageView(message: message)
                }
                ForEach(store.permissions(for: session.id)) { permission in
                    PermissionCard(permission: permission)
                }
            }
            .padding()
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(session.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store.status(for: session.id).isWorking {
                ToolbarItem(placement: .topBarTrailing) {
                    ProgressView()
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            ComposerView(session: session)
        }
        .task(id: session.id) {
            store.activeSessionID = session.id
            await store.loadMessages(sessionID: session.id)
        }
        .onDisappear {
            if store.activeSessionID == session.id {
                store.activeSessionID = nil
            }
        }
    }
}

// MARK: - Permission card

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
