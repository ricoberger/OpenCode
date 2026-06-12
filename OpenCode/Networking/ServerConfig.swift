//
//  ServerConfig.swift
//  OpenCode
//
//  The user-provided server configuration. URL and username live in
//  UserDefaults, the password lives in the Keychain.
//

import Foundation

struct ServerConfig: Equatable {
    var baseURL: URL
    var username: String?
    var password: String?

    /// HTTP Basic auth header value, if credentials are configured.
    /// The server's username defaults to "opencode" when only a password is set.
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
