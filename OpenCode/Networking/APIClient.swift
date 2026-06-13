//
//  APIClient.swift
//  OpenCode
//
//  Thin hand-written client for the opencode server REST API.
//
//  Deliberately hand-written instead of generated from the OpenAPI spec:
//  the app only uses ~10 endpoints, the spec churns with every server
//  release, and the generated unions for message parts are awkward in
//  Swift. Resilience against server changes comes from the lenient
//  decoding in APIModels.swift, not from regeneration.
//
//  The client is a stateless value type: it holds only the base URL, the
//  auth header, and a URLSession. A new instance is created whenever the
//  server config changes.
//

import Foundation

/// Errors surfaced to the UI. `errorDescription` is what the user sees in
/// the error banner / settings test result, so messages are written in
/// plain language.
enum APIError: LocalizedError {
    /// The configured URL could not be used to build a request.
    case invalidURL
    /// The response was not HTTP at all (should never happen in practice).
    case notHTTP
    /// Non-2xx response; `message` is extracted from the body when possible.
    case http(status: Int, message: String?)
    /// 2xx response whose body did not match the expected shape.
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid server URL."
        case .notHTTP:
            return "Unexpected response from server."
        case .http(let status, let message):
            // 401 deserves a specific hint because it is almost always a
            // basic-auth misconfiguration (OPENCODE_SERVER_PASSWORD).
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
    /// Pre-computed `Basic ...` header value, or `nil` when auth is off.
    let authorizationHeader: String?
    private let session: URLSession

    init(config: ServerConfig) {
        self.baseURL = config.baseURL
        self.authorizationHeader = config.authorizationHeader

        // Ephemeral: no cookie/credential/cache persistence — the server is
        // the source of truth and requests must not be answered from cache.
        // 15s request timeout per the failure-UX design; long-running agent
        // work never blocks a REST call because prompts are sent via
        // prompt_async (fire-and-forget) and results arrive over SSE.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Endpoints

    /// `GET /global/health` — used by the settings "Test Connection" button.
    func health() async throws -> HealthResponse {
        try await get("/global/health")
    }

    /// `GET /session` — all sessions, including subagent children (the
    /// store filters those out).
    func sessions() async throws -> [Session] {
        try await get("/session")
    }

    /// `POST /session` — creates an empty root session.
    func createSession() async throws -> Session {
        try await post("/session", body: CreateSessionRequest())
    }

    /// `DELETE /session/:id` — permanently removes a session and its data.
    func deleteSession(id: String) async throws {
        try await send(request(path: "/session/\(id)", method: "DELETE"))
    }

    /// `GET /session/:id/message` — full message history with parts.
    func messages(sessionID: String) async throws -> [MessageWithParts] {
        try await get("/session/\(sessionID)/message")
    }

    /// `POST /session/:id/prompt_async` — fire-and-forget prompt. Returns
    /// 204 immediately; the user message and the assistant's streaming
    /// response arrive via SSE events.
    func prompt(sessionID: String, request promptRequest: PromptRequest) async throws {
        try await send(
            request(path: "/session/\(sessionID)/prompt_async", method: "POST", body: promptRequest)
        )
    }

    /// `POST /session/:id/abort` — stops the currently running agent turn.
    func abort(sessionID: String) async throws {
        try await send(request(path: "/session/\(sessionID)/abort", method: "POST"))
    }

    /// `POST /session/:id/permissions/:permissionID` — answers a pending
    /// tool-permission request (the agent is blocked until this arrives).
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

    /// `GET /session/status` — working/idle state for all sessions at once;
    /// used during re-sync to seed the spinners.
    func sessionStatuses() async throws -> [String: SessionStatus] {
        try await get("/session/status")
    }

    /// `GET /config/providers` — providers, their models, and the server's
    /// default model selection. Feeds the model picker.
    func providers() async throws -> ProvidersResponse {
        try await get("/config/providers")
    }

    /// `GET /agent` — available agents. Feeds the agent picker.
    func agents() async throws -> [Agent] {
        try await get("/agent")
    }

    /// `GET /session/:id/todo` — the agent's current todo list for one
    /// session. Returns the full canonical list (replacement semantics);
    /// also pushed live via `todo.updated` SSE events.
    func todos(sessionID: String) async throws -> [TodoItem] {
        try await get("/session/\(sessionID)/todo")
    }

    // MARK: - Request building

    /// Builds a request with shared headers. The `some Encodable` body is
    /// generic so call sites stay type-safe; the default `nil as String?`
    /// satisfies the generic parameter for body-less requests.
    private func request(path: String, method: String, body: (some Encodable)? = nil as String?)
        -> URLRequest
    {
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

    /// GET + decode helper. Decoding failures are wrapped in
    /// `APIError.decoding` so the UI shows a friendly message instead of a
    /// raw `DecodingError`.
    private func get<T: Decodable>(_ path: String) async throws -> T {
        let data = try await send(request(path: path, method: "GET"))
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    /// POST + decode helper, for endpoints that return a body.
    private func post<T: Decodable>(_ path: String, body: some Encodable) async throws -> T {
        let data = try await send(request(path: path, method: "POST", body: body))
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    /// Executes a request and validates the HTTP status. All endpoint
    /// methods funnel through here so error handling lives in one place.
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
    /// `{"data":{"message":"..."}}` (opencode's named errors) or a plain
    /// `{"message":"..."}`. Returns `nil` for empty/unrecognized bodies.
    private static func errorMessage(from data: Data) -> String? {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return json["data"]?["message"]?.stringValue ?? json["message"]?.stringValue
    }
}
