//
//  APIClient.swift
//  OpenCode
//
//  Thin hand-written client for the opencode server REST API.
//

import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case notHTTP
    case http(status: Int, message: String?)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid server URL."
        case .notHTTP:
            return "Unexpected response from server."
        case .http(let status, let message):
            if status == 401 {
                return "Authentication failed. Check username and password."
            }
            if let message, !message.isEmpty {
                return "Server error (\(status)): \(message)"
            }
            return "Server error (\(status))."
        case .decoding:
            return "Could not read the server response."
        }
    }
}

struct APIClient {
    let baseURL: URL
    let authorizationHeader: String?
    private let session: URLSession

    init(config: ServerConfig) {
        self.baseURL = config.baseURL
        self.authorizationHeader = config.authorizationHeader

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Endpoints

    func health() async throws -> HealthResponse {
        try await get("/global/health")
    }

    func sessions() async throws -> [Session] {
        try await get("/session")
    }

    func createSession() async throws -> Session {
        try await post("/session", body: CreateSessionRequest())
    }

    func deleteSession(id: String) async throws {
        try await send(request(path: "/session/\(id)", method: "DELETE"))
    }

    func messages(sessionID: String) async throws -> [MessageWithParts] {
        try await get("/session/\(sessionID)/message")
    }

    func prompt(sessionID: String, request promptRequest: PromptRequest) async throws {
        try await send(request(path: "/session/\(sessionID)/prompt_async", method: "POST", body: promptRequest))
    }

    func abort(sessionID: String) async throws {
        try await send(request(path: "/session/\(sessionID)/abort", method: "POST"))
    }

    func respondToPermission(
        sessionID: String,
        permissionID: String,
        response: PermissionResponse
    ) async throws {
        try await send(
            request(
                path: "/session/\(sessionID)/permissions/\(permissionID)",
                method: "POST",
                body: PermissionReplyRequest(response: response)
            )
        )
    }

    func sessionStatuses() async throws -> [String: SessionStatus] {
        try await get("/session/status")
    }

    func providers() async throws -> ProvidersResponse {
        try await get("/config/providers")
    }

    func agents() async throws -> [Agent] {
        try await get("/agent")
    }

    // MARK: - Request building

    private func request(path: String, method: String, body: (some Encodable)? = nil as String?) -> URLRequest {
        var url = baseURL
        url.append(path: path)

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authorizationHeader {
            request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(body)
        }
        return request
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let data = try await send(request(path: path, method: "GET"))
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    private func post<T: Decodable>(_ path: String, body: some Encodable) async throws -> T {
        let data = try await send(request(path: path, method: "POST", body: body))
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    @discardableResult
    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.notHTTP
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = Self.errorMessage(from: data)
            throw APIError.http(status: http.statusCode, message: message)
        }
        return data
    }

    /// Extracts a human-readable message from an error response body like
    /// `{"data":{"message":"..."}}` or `{"message":"..."}`.
    private static func errorMessage(from data: Data) -> String? {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return json["data"]?["message"]?.stringValue ?? json["message"]?.stringValue
    }
}
