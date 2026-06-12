//
//  ServerConnection.swift
//  OpenCode
//
//  Owns the server configuration, the connection state machine, and the SSE
//  event loop with reconnect/backoff.
//
//  Key design point: SSE has no replay. Events missed while disconnected
//  (app backgrounded, network drop) are gone, so `onConnected` is invoked
//  on *every* (re)connect and the session store responds with a full REST
//  re-sync. Events received after that keep the state current.
//
//  Lifecycle: the root view calls `connect()` when the scene becomes active
//  and `disconnect()` when it backgrounds, so no streaming work happens in
//  the background.
//

import Foundation
import Observation

/// The connection state machine, surfaced in the sidebar status bar and
/// used to gate actions (composer, new-session button).
///
///     unconfigured → connecting → connected
///                         ↑           ↓ (drop)
///                         └── disconnected (backoff, auto-retry)
enum ConnectionState: Equatable {
    /// No server has ever been configured; show onboarding.
    case unconfigured
    case connecting
    case connected
    /// Lost or failed connection; `reason` is shown to the user when the
    /// drop was caused by an error (nil for deliberate disconnects).
    case disconnected(reason: String?)

    var isConnected: Bool { self == .connected }
}

@Observable
final class ServerConnection {
    private(set) var state: ConnectionState = .unconfigured
    private(set) var config: ServerConfig?
    /// Rebuilt whenever the config changes; `nil` while unconfigured.
    /// Consumers (SessionStore) reach the REST API through this.
    private(set) var client: APIClient?

    // Closures instead of Combine/AsyncStream fan-out: there is exactly one
    // consumer (SessionStore), and closures keep both sides trivially
    // testable. @ObservationIgnored because observing them is meaningless.

    /// Called for every event received from the server.
    @ObservationIgnored var onEvent: ((ServerEvent) -> Void)?
    /// Called whenever a connection is (re)established, to re-sync state.
    @ObservationIgnored var onConnected: (() async -> Void)?

    /// The currently running event loop. At most one exists at a time;
    /// `connect()` cancels the previous loop before starting a new one.
    @ObservationIgnored private var eventLoopTask: Task<Void, Never>?

    init() {
        // Restore persisted config so the app can connect immediately on
        // launch. Note: connecting itself is triggered by the scene-phase
        // handler in ContentView, not here.
        if let stored = ServerConfigStorage.load() {
            config = stored
            client = APIClient(config: stored)
        }
    }

    /// Saves a new configuration (from the settings sheet) and reconnects
    /// to the new server.
    func apply(config: ServerConfig) {
        ServerConfigStorage.save(config)
        self.config = config
        self.client = APIClient(config: config)
        connect()
    }

    /// Starts (or restarts) the event loop. Safe to call repeatedly — e.g.
    /// on every scene activation and from the Retry button.
    func connect() {
        disconnect()
        guard config != nil else {
            state = .unconfigured
            return
        }
        eventLoopTask = Task { await runEventLoop() }
    }

    /// Stops the event loop (scene went to background, or a reconnect is
    /// about to replace it). Keeps `unconfigured` sticky so onboarding
    /// does not flash a "Disconnected" state.
    func disconnect() {
        eventLoopTask?.cancel()
        eventLoopTask = nil
        if state != .unconfigured {
            state = .disconnected(reason: nil)
        }
    }

    /// The reconnect loop: connect → consume events → on failure wait with
    /// exponential backoff (1s … 30s) → repeat. Runs until cancelled.
    private func runEventLoop() async {
        var backoff: Duration = .seconds(1)

        while !Task.isCancelled {
            guard let config else { return }
            state = .connecting

            do {
                for try await event in EventStream.connect(config: config) {
                    if case .serverConnected = event {
                        // First event of every connection. Only now is the
                        // connection proven good: flip the state, reset the
                        // backoff, and trigger the full re-sync.
                        state = .connected
                        backoff = .seconds(1)
                        await onConnected?()
                    } else {
                        onEvent?(event)
                    }
                }
            } catch {
                // Cancellation is not an error condition — the loop was
                // told to stop (backgrounding/reconnect), so leave quietly.
                if Task.isCancelled { return }
                state = .disconnected(reason: error.localizedDescription)
            }

            // Wait before retrying. Task.sleep throws on cancellation,
            // which the `while` condition then catches.
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, .seconds(30))
        }
    }
}
