//
//  ServerConnection.swift
//  OpenCode
//
//  Owns the server configuration, the connection state machine, and the SSE
//  event loop with reconnect/backoff. SSE has no replay, so `onConnected` is
//  invoked on every (re)connect to let the session store re-sync.
//

import Foundation
import Observation

enum ConnectionState: Equatable {
    case unconfigured
    case connecting
    case connected
    case disconnected(reason: String?)

    var isConnected: Bool { self == .connected }
}

@Observable
final class ServerConnection {
    private(set) var state: ConnectionState = .unconfigured
    private(set) var config: ServerConfig?
    private(set) var client: APIClient?

    /// Called for every event received from the server.
    @ObservationIgnored var onEvent: ((ServerEvent) -> Void)?
    /// Called whenever a connection is (re)established, to re-sync state.
    @ObservationIgnored var onConnected: (() async -> Void)?

    @ObservationIgnored private var eventLoopTask: Task<Void, Never>?

    init() {
        if let stored = ServerConfigStorage.load() {
            config = stored
            client = APIClient(config: stored)
        }
    }

    func apply(config: ServerConfig) {
        ServerConfigStorage.save(config)
        self.config = config
        self.client = APIClient(config: config)
        connect()
    }

    func connect() {
        disconnect()
        guard config != nil else {
            state = .unconfigured
            return
        }
        eventLoopTask = Task { await runEventLoop() }
    }

    func disconnect() {
        eventLoopTask?.cancel()
        eventLoopTask = nil
        if state != .unconfigured {
            state = .disconnected(reason: nil)
        }
    }

    private func runEventLoop() async {
        var backoff: Duration = .seconds(1)

        while !Task.isCancelled {
            guard let config else { return }
            state = .connecting

            do {
                for try await event in EventStream.connect(config: config) {
                    if case .serverConnected = event {
                        state = .connected
                        backoff = .seconds(1)
                        await onConnected?()
                    } else {
                        onEvent?(event)
                    }
                }
            } catch {
                if Task.isCancelled { return }
                state = .disconnected(reason: error.localizedDescription)
            }

            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, .seconds(30))
        }
    }
}
