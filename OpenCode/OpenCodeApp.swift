//
//  OpenCodeApp.swift
//  OpenCode
//
//  Created by Rico Berger on 12.06.26.
//

import SwiftUI

@main
struct OpenCodeApp: App {
    @State private var connection: ServerConnection
    @State private var sessionStore: SessionStore

    init() {
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
