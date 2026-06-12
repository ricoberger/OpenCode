//
//  ContentView.swift
//  OpenCode
//
//  Root navigation: sessions sidebar, chat detail, settings sheet,
//  connection lifecycle, and the transient error banner.
//

import SwiftUI

struct ContentView: View {
    @Environment(ServerConnection.self) private var connection
    @Environment(SessionStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedSessionID: String?
    @State private var showSettings = false

    var body: some View {
        NavigationSplitView {
            SessionListView(selectedSessionID: $selectedSessionID, showSettings: $showSettings)
        } detail: {
            if let session = selectedSession {
                ChatView(session: session)
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
    }

    private var selectedSession: Session? {
        guard let selectedSessionID else { return nil }
        return store.sessions.first { $0.id == selectedSessionID }
    }

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
                    try? await Task.sleep(for: .seconds(4))
                    store.lastError = nil
                }
        }
    }
}
