//
//  SettingsView.swift
//  OpenCode
//
//  Server address and optional basic-auth credentials, with a connection
//  test against /global/health.
//
//  Saving applies the config via ServerConnection (which persists it and
//  reconnects); Cancel discards edits. The form pre-fills from the current
//  config so editing an existing setup works as expected.
//

import SwiftUI

struct SettingsView: View {
    @Environment(ServerConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss

    // Local draft state — only applied to the connection on Save.
    @State private var urlString = ""
    @State private var username = ""
    @State private var password = ""
    @State private var testResult: TestResult?

    private enum TestResult {
        case testing
        case success(version: String?)
        case failure(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://192.168.1.10:4096", text: $urlString)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Server Address")
                } footer: {
                    // The server binds to 127.0.0.1 by default, which a
                    // phone can never reach — worth spelling out here.
                    Text("Start the server with `opencode serve --hostname 0.0.0.0` so it is reachable from this device.")
                }

                Section {
                    TextField("Username (default: opencode)", text: $username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } header: {
                    Text("Authentication")
                } footer: {
                    Text("Only needed when the server was started with OPENCODE_SERVER_PASSWORD.")
                }

                Section {
                    Button("Test Connection") {
                        Task { await test() }
                    }
                    .disabled(builtConfig == nil || isTesting)

                    if let testResult {
                        testResultView(testResult)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(builtConfig == nil)
                }
            }
            .onAppear(perform: loadCurrentConfig)
        }
    }

    private var isTesting: Bool {
        if case .testing = testResult { return true }
        return false
    }

    @ViewBuilder
    private func testResultView(_ result: TestResult) -> some View {
        switch result {
        case .testing:
            HStack(spacing: 8) {
                ProgressView()
                Text("Testing…")
                    .foregroundStyle(.secondary)
            }
        case .success(let version):
            Label(
                version.map { "Connected (opencode \($0))" } ?? "Connected",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    // MARK: - Logic

    /// Validates the form into a config. `nil` disables Save/Test. Accepts
    /// bare host:port input by prepending "http://" — the common case when
    /// typing on a phone.
    private var builtConfig: ServerConfig? {
        var trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") {
            trimmed = "http://" + trimmed
        }
        guard
            let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            url.host() != nil
        else { return nil }

        return ServerConfig(
            baseURL: url,
            username: username.trimmingCharacters(in: .whitespaces),
            password: password
        )
    }

    /// Pre-fills the form with the currently saved config (if any).
    private func loadCurrentConfig() {
        guard let config = connection.config else { return }
        urlString = config.baseURL.absoluteString
        username = config.username ?? ""
        password = config.password ?? ""
    }

    /// Probes /global/health with a throwaway client built from the *draft*
    /// config (not the saved one), so users can verify before saving.
    private func test() async {
        guard let config = builtConfig else { return }
        testResult = .testing
        do {
            let health = try await APIClient(config: config).health()
            testResult = .success(version: health.version)
        } catch {
            testResult = .failure(error.localizedDescription)
        }
    }

    /// Persists the config and kicks off a reconnect to the new server.
    private func save() {
        guard let config = builtConfig else { return }
        connection.apply(config: config)
        dismiss()
    }
}
