//
//  APIModels.swift
//  OpenCode
//
//  Models mirroring the opencode server API (see /doc OpenAPI spec).
//  Decoding is intentionally lenient: unknown discriminators decode to
//  `.unknown` cases and most fields are optional, so newer server versions
//  never break the app.
//

import Foundation

// MARK: - JSONValue

/// A minimal representation of arbitrary JSON, used for tool inputs and
/// metadata whose shape is tool-specific.
enum JSONValue: Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null
}

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

extension JSONValue {
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// A compact single-value rendering used for tool argument previews.
    var displayString: String {
        switch self {
        case .string(let value): return value
        case .number(let value):
            if value == value.rounded(), abs(value) < 1e15 {
                return String(Int64(value))
            }
            return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        case .array(let values): return "[" + values.map(\.displayString).joined(separator: ", ") + "]"
        case .object(let object):
            let pairs = object.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.displayString)" }
            return "{" + pairs.joined(separator: ", ") + "}"
        }
    }
}

// MARK: - Decoding helpers

struct AnyCodingKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ string: String) { self.stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension KeyedDecodingContainer where Key == AnyCodingKey {
    func string(_ key: String) -> String? {
        try? decodeIfPresent(String.self, forKey: AnyCodingKey(key))
    }

    func double(_ key: String) -> Double? {
        try? decodeIfPresent(Double.self, forKey: AnyCodingKey(key))
    }

    func bool(_ key: String) -> Bool? {
        try? decodeIfPresent(Bool.self, forKey: AnyCodingKey(key))
    }

    func json(_ key: String) -> JSONValue? {
        try? decodeIfPresent(JSONValue.self, forKey: AnyCodingKey(key))
    }

    func nested(_ key: String) -> KeyedDecodingContainer<AnyCodingKey>? {
        try? nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey(key))
    }
}

private func dateFromEpochMilliseconds(_ value: Double?) -> Date? {
    guard let value else { return nil }
    return Date(timeIntervalSince1970: value / 1000)
}

// MARK: - Session

struct Session: Identifiable, Hashable, Decodable {
    let id: String
    var projectID: String?
    var directory: String?
    var parentID: String?
    var title: String
    var version: String?
    var timeCreated: Double?
    var timeUpdated: Double?

    var createdAt: Date? { dateFromEpochMilliseconds(timeCreated) }
    var updatedAt: Date? { dateFromEpochMilliseconds(timeUpdated) }

    var displayTitle: String {
        title.isEmpty ? "New Session" : title
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        self.id = try container.decode(String.self, forKey: AnyCodingKey("id"))
        self.projectID = container.string("projectID")
        self.directory = container.string("directory")
        self.parentID = container.string("parentID")
        self.title = container.string("title") ?? ""
        self.version = container.string("version")
        let time = container.nested("time")
        self.timeCreated = time?.double("created")
        self.timeUpdated = time?.double("updated")
    }

    init(
        id: String,
        parentID: String? = nil,
        title: String = "",
        timeCreated: Double? = nil,
        timeUpdated: Double? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.title = title
        self.timeCreated = timeCreated
        self.timeUpdated = timeUpdated
    }
}

// MARK: - Message

struct MessageInfo: Identifiable, Hashable, Decodable {
    enum Role: String {
        case user
        case assistant
        case unknown
    }

    let id: String
    var sessionID: String
    var role: Role
    var timeCreated: Double?
    var timeCompleted: Double?
    var error: AssistantError?
    var providerID: String?
    var modelID: String?
    var agent: String?
    var mode: String?

    var createdAt: Date? { dateFromEpochMilliseconds(timeCreated) }
    var isCompleted: Bool { role != .assistant || timeCompleted != nil }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        self.id = try container.decode(String.self, forKey: AnyCodingKey("id"))
        self.sessionID = container.string("sessionID") ?? ""
        self.role = container.string("role").flatMap(Role.init(rawValue:)) ?? .unknown
        let time = container.nested("time")
        self.timeCreated = time?.double("created")
        self.timeCompleted = time?.double("completed")
        self.error = container.json("error").flatMap(AssistantError.init(json:))
        self.providerID = container.string("providerID") ?? container.nested("model")?.string("providerID")
        self.modelID = container.string("modelID") ?? container.nested("model")?.string("modelID")
        self.agent = container.string("agent")
        self.mode = container.string("mode")
    }

    init(
        id: String,
        sessionID: String,
        role: Role,
        timeCreated: Double? = nil,
        timeCompleted: Double? = nil,
        error: AssistantError? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.role = role
        self.timeCreated = timeCreated
        self.timeCompleted = timeCompleted
        self.error = error
    }
}

struct AssistantError: Hashable {
    var name: String
    var message: String?

    init?(json: JSONValue) {
        guard let object = json.objectValue else { return nil }
        self.name = object["name"]?.stringValue ?? "UnknownError"
        self.message = object["data"]?["message"]?.stringValue
    }

    init(name: String, message: String?) {
        self.name = name
        self.message = message
    }

    /// Aborts are user-initiated; views suppress them rather than showing an error.
    var isAbort: Bool { name == "MessageAbortedError" }

    var displayMessage: String {
        message ?? name
    }
}

// MARK: - Parts

struct Part: Identifiable, Hashable, Decodable {
    let id: String
    var sessionID: String
    var messageID: String
    var content: PartContent

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        self.id = container.string("id") ?? UUID().uuidString
        self.sessionID = container.string("sessionID") ?? ""
        self.messageID = container.string("messageID") ?? ""
        let type = container.string("type") ?? ""
        self.content = PartContent(type: type, container: container)
    }

    init(id: String, sessionID: String, messageID: String, content: PartContent) {
        self.id = id
        self.sessionID = sessionID
        self.messageID = messageID
        self.content = content
    }
}

enum PartContent: Hashable {
    case text(TextPartData)
    case reasoning(ReasoningPartData)
    case tool(ToolPartData)
    case file(FilePartData)
    case agent(name: String)
    case subtask(SubtaskPartData)
    case patch(files: [String])
    case stepStart
    case stepFinish
    case snapshot
    case retry
    case compaction
    case unknown(type: String)

    init(type: String, container: KeyedDecodingContainer<AnyCodingKey>) {
        switch type {
        case "text":
            self = .text(TextPartData(container: container))
        case "reasoning":
            self = .reasoning(ReasoningPartData(container: container))
        case "tool":
            self = .tool(ToolPartData(container: container))
        case "file":
            self = .file(FilePartData(container: container))
        case "agent":
            self = .agent(name: container.string("name") ?? "")
        case "subtask":
            self = .subtask(SubtaskPartData(container: container))
        case "patch":
            let files = (try? container.decodeIfPresent([String].self, forKey: AnyCodingKey("files"))) ?? nil
            self = .patch(files: files ?? [])
        case "step-start":
            self = .stepStart
        case "step-finish":
            self = .stepFinish
        case "snapshot":
            self = .snapshot
        case "retry":
            self = .retry
        case "compaction":
            self = .compaction
        default:
            self = .unknown(type: type)
        }
    }
}

struct TextPartData: Hashable {
    var text: String
    var synthetic: Bool
    var ignored: Bool

    init(container: KeyedDecodingContainer<AnyCodingKey>) {
        self.text = container.string("text") ?? ""
        self.synthetic = container.bool("synthetic") ?? false
        self.ignored = container.bool("ignored") ?? false
    }

    init(text: String, synthetic: Bool = false, ignored: Bool = false) {
        self.text = text
        self.synthetic = synthetic
        self.ignored = ignored
    }
}

struct ReasoningPartData: Hashable {
    var text: String
    var timeStart: Double?
    var timeEnd: Double?

    init(container: KeyedDecodingContainer<AnyCodingKey>) {
        self.text = container.string("text") ?? ""
        let time = container.nested("time")
        self.timeStart = time?.double("start")
        self.timeEnd = time?.double("end")
    }

    init(text: String, timeStart: Double? = nil, timeEnd: Double? = nil) {
        self.text = text
        self.timeStart = timeStart
        self.timeEnd = timeEnd
    }
}

struct ToolPartData: Hashable {
    enum Status: String {
        case pending
        case running
        case completed
        case error
        case unknown
    }

    var tool: String
    var callID: String?
    var status: Status
    var input: JSONValue?
    var output: String?
    var title: String?
    var errorMessage: String?
    var timeStart: Double?
    var timeEnd: Double?

    init(container: KeyedDecodingContainer<AnyCodingKey>) {
        self.tool = container.string("tool") ?? ""
        self.callID = container.string("callID")
        let state = container.nested("state")
        self.status = state?.string("status").flatMap(Status.init(rawValue:)) ?? .unknown
        self.input = state?.json("input")
        self.output = state?.string("output")
        self.title = state?.string("title")
        self.errorMessage = state?.string("error")
        let time = state?.nested("time")
        self.timeStart = time?.double("start")
        self.timeEnd = time?.double("end")
    }

    init(
        tool: String,
        callID: String? = nil,
        status: Status,
        input: JSONValue? = nil,
        output: String? = nil,
        title: String? = nil,
        errorMessage: String? = nil
    ) {
        self.tool = tool
        self.callID = callID
        self.status = status
        self.input = input
        self.output = output
        self.title = title
        self.errorMessage = errorMessage
    }

    /// The most useful one-line summary of what the tool is doing.
    var summary: String {
        if let title, !title.isEmpty { return title }
        for key in ["command", "filePath", "path", "pattern", "query", "url", "description"] {
            if let value = input?[key]?.stringValue, !value.isEmpty { return value }
        }
        return input?.displayString ?? ""
    }
}

struct FilePartData: Hashable {
    var mime: String?
    var filename: String?
    var url: String?

    init(container: KeyedDecodingContainer<AnyCodingKey>) {
        self.mime = container.string("mime")
        self.filename = container.string("filename")
        self.url = container.string("url")
    }

    init(mime: String?, filename: String?, url: String?) {
        self.mime = mime
        self.filename = filename
        self.url = url
    }
}

struct SubtaskPartData: Hashable {
    var prompt: String?
    var description: String?
    var agent: String?

    init(container: KeyedDecodingContainer<AnyCodingKey>) {
        self.prompt = container.string("prompt")
        self.description = container.string("description")
        self.agent = container.string("agent")
    }
}

// MARK: - Message + parts envelope

struct MessageWithParts: Identifiable, Hashable, Decodable {
    var info: MessageInfo
    var parts: [Part]

    var id: String { info.id }
}

// MARK: - Permission

struct Permission: Identifiable, Hashable, Decodable {
    let id: String
    var type: String
    var sessionID: String
    var messageID: String?
    var callID: String?
    var title: String
    var metadata: JSONValue?
    var patterns: [String]
    var timeCreated: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        self.id = try container.decode(String.self, forKey: AnyCodingKey("id"))
        self.type = container.string("type") ?? ""
        self.sessionID = container.string("sessionID") ?? ""
        self.messageID = container.string("messageID")
        self.callID = container.string("callID")
        self.title = container.string("title") ?? ""
        self.metadata = container.json("metadata")
        switch container.json("pattern") {
        case .string(let value): self.patterns = [value]
        case .array(let values): self.patterns = values.compactMap(\.stringValue)
        default: self.patterns = []
        }
        self.timeCreated = container.nested("time")?.double("created")
    }

    init(
        id: String,
        type: String,
        sessionID: String,
        messageID: String? = nil,
        callID: String? = nil,
        title: String,
        metadata: JSONValue? = nil,
        patterns: [String] = []
    ) {
        self.id = id
        self.type = type
        self.sessionID = sessionID
        self.messageID = messageID
        self.callID = callID
        self.title = title
        self.metadata = metadata
        self.patterns = patterns
    }
}

enum PermissionResponse: String, Encodable, CaseIterable {
    case once
    case always
    case reject
}

// MARK: - Session status

enum SessionStatus: Hashable, Decodable {
    case idle
    case busy
    case retry(attempt: Int?, message: String?)
    case unknown(String)

    var isWorking: Bool {
        switch self {
        case .busy, .retry: return true
        case .idle, .unknown: return false
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        let type = container.string("type") ?? ""
        switch type {
        case "idle":
            self = .idle
        case "busy":
            self = .busy
        case "retry":
            let attempt = container.double("attempt").map(Int.init)
            self = .retry(attempt: attempt, message: container.string("message"))
        default:
            self = .unknown(type)
        }
    }
}

// MARK: - Providers & agents

struct ProvidersResponse: Decodable {
    var providers: [Provider]
    var defaults: [String: String]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        self.providers = (try? container.decodeIfPresent([Provider].self, forKey: AnyCodingKey("providers"))) ?? []
        self.defaults = (try? container.decodeIfPresent([String: String].self, forKey: AnyCodingKey("default"))) ?? [:]
    }

    init(providers: [Provider], defaults: [String: String]) {
        self.providers = providers
        self.defaults = defaults
    }
}

struct Provider: Identifiable, Hashable, Decodable {
    let id: String
    var name: String
    var models: [String: ModelInfo]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        self.id = try container.decode(String.self, forKey: AnyCodingKey("id"))
        self.name = container.string("name") ?? id
        self.models = (try? container.decodeIfPresent([String: ModelInfo].self, forKey: AnyCodingKey("models"))) ?? [:]
    }

    init(id: String, name: String, models: [String: ModelInfo]) {
        self.id = id
        self.name = name
        self.models = models
    }
}

struct ModelInfo: Hashable, Decodable {
    var id: String?
    var name: String?
    var status: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        self.id = container.string("id")
        self.name = container.string("name")
        self.status = container.string("status")
    }

    init(id: String?, name: String?, status: String? = nil) {
        self.id = id
        self.name = name
        self.status = status
    }
}

struct Agent: Identifiable, Hashable, Decodable {
    var id: String { name }
    let name: String
    var description: String?
    var mode: String?
    var builtIn: Bool?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        self.name = try container.decode(String.self, forKey: AnyCodingKey("name"))
        self.description = container.string("description")
        self.mode = container.string("mode")
        self.builtIn = container.bool("builtIn")
    }

    init(name: String, description: String? = nil, mode: String? = nil) {
        self.name = name
        self.description = description
        self.mode = mode
    }

    var isSelectable: Bool { mode != "subagent" }
}

// MARK: - Requests

struct ModelRef: Codable, Hashable {
    var providerID: String
    var modelID: String
}

struct PromptRequest: Encodable {
    struct TextPartInput: Encodable {
        var type = "text"
        var text: String
    }

    var model: ModelRef?
    var agent: String?
    var parts: [TextPartInput]

    init(text: String, model: ModelRef?, agent: String?) {
        self.model = model
        self.agent = agent
        self.parts = [TextPartInput(text: text)]
    }
}

struct CreateSessionRequest: Encodable {
    var parentID: String?
    var title: String?
}

struct PermissionReplyRequest: Encodable {
    var response: PermissionResponse
}

// MARK: - Misc responses

struct HealthResponse: Decodable {
    var healthy: Bool?
    var version: String?
}

// MARK: - Server events (SSE)

enum ServerEvent: Decodable {
    case serverConnected
    case messageUpdated(MessageInfo)
    case messageRemoved(sessionID: String, messageID: String)
    case partUpdated(Part)
    case partRemoved(sessionID: String, messageID: String, partID: String)
    case permissionUpdated(Permission)
    case permissionReplied(sessionID: String, permissionID: String)
    case sessionStatus(sessionID: String, status: SessionStatus)
    case sessionIdle(sessionID: String)
    case sessionCreated(Session)
    case sessionUpdated(Session)
    case sessionDeleted(Session)
    case sessionError(sessionID: String?, error: AssistantError?)
    case unknown(type: String)

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        let type = container.string("type") ?? ""
        let properties = container.nested("properties")

        func decodeProperties<T: Decodable>(_ valueType: T.Type, _ key: String? = nil) -> T? {
            if let key {
                return try? container.nested("properties")?
                    .decodeIfPresent(T.self, forKey: AnyCodingKey(key))
            }
            return try? container.decodeIfPresent(T.self, forKey: AnyCodingKey("properties"))
        }

        switch type {
        case "server.connected":
            self = .serverConnected
        case "message.updated":
            if let info = decodeProperties(MessageInfo.self, "info") {
                self = .messageUpdated(info)
            } else {
                self = .unknown(type: type)
            }
        case "message.removed":
            self = .messageRemoved(
                sessionID: properties?.string("sessionID") ?? "",
                messageID: properties?.string("messageID") ?? ""
            )
        case "message.part.updated":
            if let part = decodeProperties(Part.self, "part") {
                self = .partUpdated(part)
            } else {
                self = .unknown(type: type)
            }
        case "message.part.removed":
            self = .partRemoved(
                sessionID: properties?.string("sessionID") ?? "",
                messageID: properties?.string("messageID") ?? "",
                partID: properties?.string("partID") ?? ""
            )
        case "permission.updated":
            if let permission = decodeProperties(Permission.self) {
                self = .permissionUpdated(permission)
            } else {
                self = .unknown(type: type)
            }
        case "permission.replied":
            self = .permissionReplied(
                sessionID: properties?.string("sessionID") ?? "",
                permissionID: properties?.string("permissionID") ?? ""
            )
        case "session.status":
            if let status = decodeProperties(SessionStatus.self, "status") {
                self = .sessionStatus(sessionID: properties?.string("sessionID") ?? "", status: status)
            } else {
                self = .unknown(type: type)
            }
        case "session.idle":
            self = .sessionIdle(sessionID: properties?.string("sessionID") ?? "")
        case "session.created":
            if let session = decodeProperties(Session.self, "info") {
                self = .sessionCreated(session)
            } else {
                self = .unknown(type: type)
            }
        case "session.updated":
            if let session = decodeProperties(Session.self, "info") {
                self = .sessionUpdated(session)
            } else {
                self = .unknown(type: type)
            }
        case "session.deleted":
            if let session = decodeProperties(Session.self, "info") {
                self = .sessionDeleted(session)
            } else {
                self = .unknown(type: type)
            }
        case "session.error":
            self = .sessionError(
                sessionID: properties?.string("sessionID"),
                error: properties?.json("error").flatMap(AssistantError.init(json:))
            )
        default:
            self = .unknown(type: type)
        }
    }
}
