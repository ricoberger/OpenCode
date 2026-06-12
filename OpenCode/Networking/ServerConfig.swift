//
//  ServerConfig.swift
//  OpenCode
//
//  The user-provided server configuration and its persistence.
//
//  Storage split (by sensitivity):
//  - URL + username → UserDefaults (not secrets)
//  - password       → Keychain (secret)
//
//  v1 supports exactly one saved server. If multiple servers are ever
//  needed, URL/username move into a model keyed by server ID and the
//  Keychain entry gets keyed accordingly — nothing here blocks that.
//

import Foundation

struct ServerConfig: Equatable {
    /// Scheme + host + port, e.g. `http://192.168.1.10:4096`. Plain HTTP is
    /// expected (the app opts out of ATS for this reason).
    var baseURL: URL
    var username: String?
    var password: String?

    /// HTTP Basic auth header value, if credentials are configured.
    ///
    /// Auth is considered "on" purely by the presence of a password, since
    /// the server enables it via OPENCODE_SERVER_PASSWORD. The username
    /// defaults to "opencode" — the same default the server uses when
    /// OPENCODE_SERVER_USERNAME is not set.
    var authorizationHeader: String? {
        guard let password, !password.isEmpty else { return nil }
        let user = (username?.isEmpty == false) ? username! : "opencode"
        let credentials = Data("\(user):\(password)".utf8).base64EncodedString()
        return "Basic \(credentials)"
    }
}

enum ServerConfigStorage {
    private static let urlKey = "serverURL"
    private static let usernameKey = "serverUsername"
    private static let passwordKey = "serverPassword"

    /// Loads the saved configuration, or `nil` when the app has never been
    /// configured (drives the "Set Up Server" empty state).
    static func load() -> ServerConfig? {
        guard
            let urlString = UserDefaults.standard.string(forKey: urlKey),
            let url = URL(string: urlString)
        else { return nil }

        return ServerConfig(
            baseURL: url,
            username: UserDefaults.standard.string(forKey: usernameKey),
            password: Keychain.get(passwordKey)
        )
    }

    /// Persists the configuration. Empty username/password are treated as
    /// "remove the stored value" so clearing the fields in settings really
    /// clears the stored credentials.
    static func save(_ config: ServerConfig) {
        UserDefaults.standard.set(config.baseURL.absoluteString, forKey: urlKey)

        if let username = config.username, !username.isEmpty {
            UserDefaults.standard.set(username, forKey: usernameKey)
        } else {
            UserDefaults.standard.removeObject(forKey: usernameKey)
        }

        if let password = config.password, !password.isEmpty {
            Keychain.set(password, for: passwordKey)
        } else {
            Keychain.delete(passwordKey)
        }
    }
}
