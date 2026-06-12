//
//  ContentView.swift
//  OpenCode
//
//  Root navigation: sessions sidebar, chat detail, settings sheet,
//  connection lifecycle, and the transient error banner.
//
//  Uses NavigationSplitView so the iPad gets a real sidebar+detail layout
//  while the iPhone collapses to a push stack automatically.
//

import SwiftUI

struct ContentView: View {
    @Environment(ServerConnection.self) private var connection
    @Environment(SessionStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    /// Selection is stored as the session *ID* (not the Session value):
    /// session structs are replaced on every SSE update, and an ID survives
    /// those replacements.
    @State private var selectedSessionID: String?
    @State private var showSettings = false

    var body: some View {
        NavigationSplitView {
            SessionListView(selectedSessionID: $selectedSessionID, showSettings: $showSettings)
        } detail: {
            if let session = selectedSession {
                ChatView(session: session)
                    // Key the chat's *identity* to the session: switching
                    // sessions must rebuild the subtree (fresh load task,
                    // scroll position, composer draft, expansion states).
                    // Without this, SwiftUI reuses the same ChatView and
                    // state from the previous session leaks into the next.
                    // Title/timestamp updates keep the id stable, so live
                    // session updates do not recreate the view.
                    .id(session.id)
            } else {
                ContentUnavailableView(
                    "No Session Selected",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Select a session or create a new one.")
                )
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .overlay(alignment: .top) {
            errorBanner
        }
        // Connection follows the scene lifecycle: stream while visible,
        // tear down in the background, reconnect (with full re-sync, see
        // ServerConnection) when the user comes back. `.active` also fires
        // at launch, which is what establishes the initial connection.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                connection.connect()
            case .background:
                connection.disconnect()
            default:
                break
            }
        }
        // Message loading is driven by the *selection*, not by ChatView's
        // lifecycle: on iPhone, NavigationSplitView fires a spurious
        // disappear/appear on the detail during the push transition, which
        // cancels a `.task` mid-request without ever restarting it (the
        // view identity never changed). Selection changes have no such
        // quirks. The unstructured Task is deliberate — it must survive
        // view transitions; concurrent loads are safe because results are
        // written keyed by session ID.
        .onChange(of: selectedSessionID) { _, newID in
            store.activeSessionID = newID
            if let newID {
                Task { await store.loadMessages(sessionID: newID) }
            }
        }
    }

    /// Resolves the selected ID against the live session list, so the chat
    /// always sees the freshest title/timestamps. Yields nil (placeholder
    /// detail) when the selected session was deleted.
    private var selectedSession: Session? {
        guard let selectedSessionID else { return nil }
        return store.sessions.first { $0.id == selectedSessionID }
    }

    /// Transient toast for action/sync errors reported by the store.
    /// Auto-dismisses after a few seconds; tapping is not required.
    @ViewBuilder
    private var errorBanner: some View {
        if let message = store.lastError {
            Text(message)
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.red.opacity(0.9), in: Capsule())
                .foregroundStyle(.white)
                .padding(.top, 4)
                .padding(.horizontal)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task {
                    // Tied to the banner's lifetime: if the banner is
                    // replaced by a newer error, this task is cancelled and
                    // the new banner starts its own timer.
                    try? await Task.sleep(for: .seconds(4))
                    store.lastError = nil
                }
        }
    }
}
