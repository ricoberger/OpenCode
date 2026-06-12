//
//  ComposerView.swift
//  OpenCode
//
//  Prompt input with send and stop.
//
//  Behavior decisions baked in here:
//  - The draft is only cleared after the server accepts the prompt, so a
//    failed send never loses typed text.
//  - Sending while the agent is busy is allowed — the server queues the
//    prompt. The stop button appears *next to* send while working.
//  - Return inserts a newline (mobile chat convention); sending is always
//    explicit via the send button.
//  - Model/agent selection lives in the chat settings menu (see ChatView).
//

import SwiftUI

struct ComposerView: View {
    @Environment(ServerConnection.self) private var connection
    @Environment(SessionStore.self) private var store

    let session: Session

    @State private var draft = ""
    /// True while a prompt request is in flight; debounces the send button.
    @State private var sending = false
    /// Tracked so the Return-key handler can keep the field focused (the
    /// text system tries to end editing on hardware Return).
    @FocusState private var isFocused: Bool

    private var isWorking: Bool {
        store.status(for: session.id).isWorking
    }

    private var isConnected: Bool {
        connection.state.isConnected
    }

    private var canSend: Bool {
        isConnected && !sending
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                isConnected ? "Message" : "Disconnected",
                text: $draft,
                axis: .vertical
            )
            // Grows with content up to 6 lines, then scrolls internally.
            .lineLimit(1...6)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 18))
            // Typing while disconnected would silently go nowhere —
            // disable and let the placeholder explain why.
            .disabled(!isConnected)
            .focused($isFocused)
            // The software keyboard's return key inserts a newline in a
            // vertical-axis TextField, but *hardware* keyboards
            // (Simulator with the Mac keyboard, iPad keyboards) deliver
            // Return as a key event that would otherwise do nothing.
            // Intercept it so both keyboards behave the same.
            // Limitation: SwiftUI exposes no cursor position for
            // TextField, so the newline is appended at the end — fine
            // for linear chat typing.
            .onKeyPress(.return) {
                draft += "\n"
                // The text system still tries to end editing on hardware
                // Return despite us handling the event; re-assert focus
                // on the next runloop so the caret stays in the field.
                Task { isFocused = true }
                return .handled
            }

            // Stop appears only while the agent works; send stays
            // available so the user can queue a follow-up.
            if isWorking {
                Button {
                    Task { await store.abort(sessionID: session.id) }
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                        // Optically centers the icon against a
                        // single-line field (whose text sits inside 8pt
                        // vertical padding); with .bottom alignment the
                        // button stays pinned as the field grows.
                        .padding(.bottom, 6)
                }
                .accessibilityLabel("Stop")
            }

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    // Same optical centering as the stop button.
                    .padding(.bottom, 6)
            }
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Actions

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }

        sending = true
        Task {
            defer { sending = false }
            do {
                try await store.send(text: text, sessionID: session.id)
                // Only clear after the server accepted the prompt.
                draft = ""
            } catch {
                // Draft is kept; the error banner (fed by the store)
                // reports the failure.
            }
        }
    }
}
