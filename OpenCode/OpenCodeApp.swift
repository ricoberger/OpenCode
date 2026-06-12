//
//  OpenCodeApp.swift
//  OpenCode
//
//  Created by Rico Berger on 12.06.26.
//
//  App entry point. Composition root for the two app-wide stores:
//
//  - ServerConnection: config + connection state + SSE event loop
//  - SessionStore: all session/message/permission state, fed by the
//    connection's events
//
//  Both are created once here and injected into the environment; views
//  resolve them via @Environment. There is no local persistence layer —
//  the opencode server is the source of truth.
//

import SwiftUI

@main
struct OpenCodeApp: App {
    @State private var connection: ServerConnection
    @State private var sessionStore: SessionStore

    init() {
        // SessionStore wires itself to the connection's callbacks in its
        // initializer, so the two must be created together, in this order.
        let connection = ServerConnection()
        _connection = State(initialValue: connection)
        _sessionStore = State(initialValue: SessionStore(connection: connection))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(connection)
                .environment(sessionStore)
        }
    }
}
