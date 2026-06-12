//
//  ComposerView.swift
//  OpenCode
//
//  Prompt input with model/agent pickers, send, and stop.
//
//  Behavior decisions baked in here:
//  - The draft is only cleared after the server accepts the prompt, so a
//    failed send never loses typed text.
//  - Sending while the agent is busy is allowed — the server queues the
//    prompt. The stop button appears *next to* send while working.
//  - Return inserts a newline (mobile chat convention); sending is always
//    explicit via the send button.
//  - Model/agent selection is app-wide and persisted (see SessionStore).
//

import SwiftUI

struct ComposerView: View {
    @Environment(ServerConnection.self) private var connection
    @Environment(SessionStore.self) private var store

    let session: Session

    @State private var draft = ""
    /// True while a prompt request is in flight; debounces the send button.
    @State private var sending = false

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
        VStack(alignment: .leading, spacing: 8) {
            // Picker row above the text field — compact chips, not pickers,
            // to keep the composer low.
            HStack(spacing: 8) {
                modelMenu
                agentMenu
                Spacer()
            }

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

                // Stop appears only while the agent works; send stays
                // available so the user can queue a follow-up.
                if isWorking {
                    Button {
                        Task { await store.abort(sessionID: session.id) }
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.red)
                    }
                    .accessibilityLabel("Stop")
                }

                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Pickers

    /// Model picker: flat menu of every model across providers, with a
    /// checkmark on the current selection.
    private var modelMenu: some View {
        Menu {
            ForEach(store.availableModels, id: \.ref) { model in
                Button {
                    store.selectedModel = model.ref
                } label: {
                    if store.selectedModel == model.ref {
                        Label(model.displayName, systemImage: "checkmark")
                    } else {
                        Text(model.displayName)
                    }
                }
            }
        } label: {
            chip(selectedModelName, systemImage: "cpu")
        }
        // Empty until the first successful providers fetch.
        .disabled(store.availableModels.isEmpty)
    }

    /// Agent picker: primary agents only (the store filters subagents).
    private var agentMenu: some View {
        Menu {
            ForEach(store.selectableAgents) { agent in
                Button {
                    store.selectedAgent = agent.name
                } label: {
                    if store.selectedAgent == agent.name {
                        Label(agent.name, systemImage: "checkmark")
                    } else {
                        Text(agent.name)
                    }
                }
            }
        } label: {
            chip(store.selectedAgent ?? "agent", systemImage: "person.text.rectangle")
        }
        .disabled(store.selectableAgents.isEmpty)
    }

    /// Display name of the selected model. Falls back to the raw model ID
    /// when the model vanished from the server (still shown, still usable —
    /// the server decides whether it accepts it).
    private var selectedModelName: String {
        guard let selected = store.selectedModel else { return "model" }
        return store.availableModels.first { $0.ref == selected }?.displayName
            ?? selected.modelID
    }

    /// Shared chip styling for the two picker labels.
    private func chip(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.fill.quaternary, in: Capsule())
            .foregroundStyle(.secondary)
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
