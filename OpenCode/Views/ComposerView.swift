//
//  ComposerView.swift
//  OpenCode
//
//  Prompt input with model/agent pickers, send, and stop. The draft is only
//  cleared after the server accepts the prompt, so failures lose nothing.
//

import SwiftUI

struct ComposerView: View {
    @Environment(ServerConnection.self) private var connection
    @Environment(SessionStore.self) private var store

    let session: Session

    @State private var draft = ""
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
                .lineLimit(1...6)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 18))
                .disabled(!isConnected)

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
        .disabled(store.availableModels.isEmpty)
    }

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

    private var selectedModelName: String {
        guard let selected = store.selectedModel else { return "model" }
        return store.availableModels.first { $0.ref == selected }?.displayName
            ?? selected.modelID
    }

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
                draft = ""
            } catch {
                // Draft is kept; the error banner reports the failure.
            }
        }
    }
}
