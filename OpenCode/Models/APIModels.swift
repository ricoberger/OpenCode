//
//  APIModels.swift
//  OpenCode
//
//  Models mirroring the opencode server API (see the OpenAPI spec served at
//  `http://<server>/doc`, or `types.gen.ts` in the opencode repository).
//
//  Decoding philosophy: the opencode server evolves quickly and this client
//  is hand-written, so every model decodes *leniently*:
//
//  - Unknown discriminator values (part types, event types, roles, tool
//    statuses) decode to dedicated `.unknown` cases instead of throwing.
//  - Every field that is not strictly required for identity is optional or
//    has a default value.
//  - Nested containers are accessed with `try?` so a missing or malformed
//    sub-object degrades to `nil` rather than failing the whole payload.
//
//  The net effect: an older app version talking to a newer server renders
//  placeholders for the parts it does not understand, but never crashes or
//  fails to show a conversation.
//
//  All timestamps from the server are JavaScript-style epoch *milliseconds*.
//

import Foundation

// MARK: - JSONValue

/// A minimal representation of arbitrary JSON, used for tool inputs and
/// metadata whose shape is tool-specific (e.g. `{"command": "ls"}` for bash,
/// `{"filePath": "..."}` for read/edit). The app never needs to interpret
/// these fully — it only extracts well-known keys for display.
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
        // Order matters: try Bool before Double because JSONDecoder happily
        // decodes `true` as a number on some platforms, and a bare string
        // would never match the earlier cases.
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
            // Truly undecodable content degrades to null instead of throwing,
            // in keeping with the lenient-decoding philosophy above.
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
    /// The wrapped string if this value is a string, otherwise `nil`.
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// The wrapped dictionary if this value is an object, otherwise `nil`.
    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Convenience key lookup for object values, enabling chained access
    /// like `json["data"]?["message"]?.stringValue`.
    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// A compact single-line rendering used for tool argument previews in
    /// the UI. Not meant to round-trip — just to be readable.
    var displayString: String {
        switch self {
        case .string(let value): return value
        case .number(let value):
            // Render whole numbers without a trailing ".0".
            if value == value.rounded(), abs(value) < 1e15 {
                return String(Int64(value))
            }
            return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        case .array(let values):
            return "[" + values.map(\.displayString).joined(separator: ", ") + "]"
        case .object(let object):
            // Sort keys for stable output (dictionaries have no order).
            let pairs = object.sorted { $0.key < $1.key }.map {
                "\($0.key): \($0.value.displayString)"
            }
            return "{" + pairs.joined(separator: ", ") + "}"
        }
    }
}

// MARK: - Decoding helpers

/// A `CodingKey` that can represent any string key. Used by all the custom
/// `init(from:)` implementations below so they can probe for keys without
/// declaring a `CodingKeys` enum per type.
struct AnyCodingKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ string: String) { self.stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Lenient accessors: each returns `nil` (instead of throwing) when the key
/// is missing or its value has an unexpected type. These are the workhorses
/// of the lenient-decoding strategy.
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

    /// A nested keyed container (e.g. the `time` or `state` sub-objects),
    /// or `nil` when absent.
    func nested(_ key: String) -> KeyedDecodingContainer<AnyCodingKey>? {
        try? nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey(key))
    }
}

/// Converts a server timestamp (epoch milliseconds) to a `Date`.
private func dateFromEpochMilliseconds(_ value: Double?) -> Date? {
    guard let value else { return nil }
    return Date(timeIntervalSince1970: value / 1000)
}

// MARK: - Session

/// A conversation on the server (`GET /session`). Sessions with a non-nil
/// `parentID` are subagent runs spawned by a Task tool; the UI hides them.
struct Session: Identifiable, Hashable, Decodable {
    let id: String
    var projectID: String?
    var directory: String?
    /// Set when this session is a child (subagent) session.
    var parentID: String?
    /// Server-generated after the first exchange; empty for new sessions.
    var title: String
    var version: String?
    /// Epoch milliseconds.
    var timeCreated: Double?
    /// Epoch milliseconds; drives the sidebar sort order.
    var timeUpdated: Double?

    var createdAt: Date? { dateFromEpochMilliseconds(timeCreated) }
    var updatedAt: Date? { dateFromEpochMilliseconds(timeUpdated) }

    /// What the sidebar shows: falls back to a placeholder until the server
    /// has generated a title.
    var displayTitle: String {
        title.isEmpty ? "New Session" : title
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        // `id` is the only field we genuinely cannot proceed without.
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

    /// Memberwise convenience for tests and previews.
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

/// Metadata of a single message (user prompt or assistant turn). The server
/// models user and assistant messages as distinct types; this app flattens
/// them into one struct because the UI only branches on `role`.
struct MessageInfo: Identifiable, Hashable, Decodable {
    enum Role: String {
        case user
        case assistant
        /// Forward-compatibility: any role this app version does not know.
        case unknown
    }

    let id: String
    var sessionID: String
    var role: Role
    /// Epoch milliseconds.
    var timeCreated: Double?
    /// Epoch milliseconds; only set on assistant messages once they finish.
    var timeCompleted: Double?
    /// Assistant-only: the error that ended the turn, if any.
    var error: AssistantError?
    var providerID: String?
    var modelID: String?
    /// User messages carry the agent they were sent with.
    var agent: String?
    /// Assistant messages carry the mode (agent) they ran under.
    var mode: String?

    var createdAt: Date? { dateFromEpochMilliseconds(timeCreated) }

    /// User messages are always "complete"; assistant messages are complete
    /// once the server stamps `time.completed`.
    var isCompleted: Bool { role != .assistant || timeCompleted != nil }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        self.id = try container.decode(String.self, forKey: AnyCodingKey("id"))
        self.sessionID = container.string("sessionID") ?? ""
        // Unknown roles must not throw — map them to `.unknown`.
        self.role = container.string("role").flatMap(Role.init(rawValue:)) ?? .unknown
        let time = container.nested("time")
        self.timeCreated = time?.double("created")
        self.timeCompleted = time?.double("completed")
        self.error = container.json("error").flatMap(AssistantError.init(json:))
        // User messages nest provider/model under `model`, assistant
        // messages have them at the top level — accept either shape.
        self.providerID =
            container.string("providerID") ?? container.nested("model")?.string("providerID")
        self.modelID = container.string("modelID") ?? container.nested("model")?.string("modelID")
        self.agent = container.string("agent")
        self.mode = container.string("mode")
    }

    /// Memberwise convenience for tests and for the placeholder messages the
    /// store creates when a part arrives before its `message.updated` event.
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

/// A named error attached to an assistant message or a `session.error`
/// event. The server emits a union of error types (`APIError`,
/// `ProviderAuthError`, `MessageAbortedError`, ...) that all share the shape
/// `{ name, data: { message? } }` — which is all the UI needs.
struct AssistantError: Hashable {
    var name: String
    var message: String?

    /// Builds the error from raw JSON; returns `nil` when the value is not
    /// an object (e.g. the field was absent or had an unexpected shape).
    init?(json: JSONValue) {
        guard let object = json.objectValue else { return nil }
        self.name = object["name"]?.stringValue ?? "UnknownError"
        self.message = object["data"]?["message"]?.stringValue
    }

    init(name: String, message: String?) {
        self.name = name
        self.message = message
    }

    /// Aborts are user-initiated (the stop button); views suppress them
    /// rather than presenting them as failures.
    var isAbort: Bool { name == "MessageAbortedError" }

    var displayMessage: String {
        message ?? name
    }
}

// MARK: - Parts

/// One piece of a message. Assistant turns are sequences of typed parts
/// (text, reasoning, tool calls, ...) that stream in incrementally via
/// `message.part.updated` events.
///
/// The common identity fields live on `Part` itself; the type-specific
/// payload lives in `content`. The identity fields matter beyond display:
/// the session store routes incoming part updates by
/// `(sessionID, messageID, id)`.
struct Part: Identifiable, Hashable, Decodable {
    let id: String
    var sessionID: String
    var messageID: String
    var content: PartContent

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        // Parts always carry an id in practice; the UUID fallback just
        // guarantees `Identifiable` holds even for malformed payloads.
        self.id = container.string("id") ?? UUID().uuidString
        self.sessionID = container.string("sessionID") ?? ""
        self.messageID = container.string("messageID") ?? ""
        let type = container.string("type") ?? ""
        self.content = PartContent(type: type, container: container)
    }

    /// Memberwise convenience for tests and previews.
    init(id: String, sessionID: String, messageID: String, content: PartContent) {
        self.id = id
        self.sessionID = sessionID
        self.messageID = messageID
        self.content = content
    }
}

/// The type-specific payload of a `Part`, discriminated by the server's
/// `type` field. Cases the UI renders carry data; cases the UI hides
/// (structural markers like step boundaries) are bare.
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
    /// Any part type this app version does not know. Rendered as a small
    /// placeholder chip so new server features degrade visibly but safely.
    case unknown(type: String)

    /// Never throws: unknown `type` strings become `.unknown`, and each
    /// payload initializer tolerates missing fields.
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
            let files =
                (try? container.decodeIfPresent([String].self, forKey: AnyCodingKey("files")))
                ?? nil
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

/// Payload of a `text` part — the assistant's (or user's) prose.
struct TextPartData: Hashable {
    var text: String
    /// Synthetic parts are injected by the system (not typed by the user);
    /// the UI hides them.
    var synthetic: Bool
    /// Ignored parts were reverted/excluded; the UI hides them too.
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

/// Payload of a `reasoning` part — extended thinking from reasoning models.
/// Rendered collapsed behind a disclosure.
struct ReasoningPartData: Hashable {
    var text: String
    var timeStart: Double?
    /// Unset while the model is still thinking.
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

/// Payload of a `tool` part — a single tool invocation and its lifecycle.
///
/// The server models the state as a discriminated union
/// (`pending → running → completed | error`), each variant carrying
/// different fields. This struct flattens the union: `status` says which
/// variant it was, and the variant-specific fields are simply `nil` when
/// not applicable. That makes the streaming UI trivial — the same view
/// re-renders as fields fill in.
struct ToolPartData: Hashable {
    enum Status: String {
        case pending
        case running
        case completed
        case error
        /// Forward-compatibility for new lifecycle states.
        case unknown
    }

    /// Tool name as registered on the server (`bash`, `edit`, `read`, ...).
    var tool: String
    var callID: String?
    var status: Status
    /// Tool-specific arguments (shape varies by tool).
    var input: JSONValue?
    /// Only present once `status == .completed`.
    var output: String?
    /// Server-provided human-readable summary (e.g. the file path).
    var title: String?
    /// Only present when `status == .error`.
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

    /// The most useful one-line summary of what the tool is doing, for the
    /// collapsed tool card. Prefers the server's title, then probes the
    /// input for the keys our built-in tools use, then falls back to a
    /// compact dump of the whole input.
    var summary: String {
        if let title, !title.isEmpty { return title }
        for key in ["command", "filePath", "path", "pattern", "query", "url", "description"] {
            if let value = input?[key]?.stringValue, !value.isEmpty { return value }
        }
        return input?.displayString ?? ""
    }
}

/// Payload of a `file` part — an attachment (image, document, ...).
/// v1 renders these as a chip; sending attachments is not supported yet.
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

/// Payload of a `subtask` part — a queued subagent run (Task tool).
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

// MARK: - Todos

/// A single agent-planned task item, owned server-side by the `TodoWrite`
/// tool. Surfaced as session-level state via `GET /session/:id/todo` plus
/// the `todo.updated` SSE event — both deliver the *full* list (replacement
/// semantics), so the store stores it whole and never patches in place.
///
/// The wire shape has no stable id; iteration uses `id: \.self` (the struct
/// is `Hashable`). Two todos that hash identically across an update will
/// collapse into one row, which is acceptable: the agent does not emit
/// duplicate plan items in practice.
struct TodoItem: Hashable, Decodable {
    enum Status: String {
        case pending
        case inProgress = "in_progress"
        case completed
        case cancelled
        /// Forward-compatibility for new status values (e.g. a future
        /// "blocked"). Renders with the unknown-discriminator glyph.
        case unknown
    }

    var content: String
    var status: Status
    /// Required by the spec; carried on the model but not rendered by v1
    /// (the agent emits "medium" for almost everything — low signal).
    var priority: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        self.content = container.string("content") ?? ""
        self.status = container.string("status").flatMap(Status.init(rawValue:)) ?? .unknown
        self.priority = container.string("priority") ?? ""
    }

    /// Memberwise convenience for tests and previews.
    init(content: String, status: Status, priority: String = "medium") {
        self.content = content
        self.status = status
        self.priority = priority
    }
}

// MARK: - Message + parts envelope

/// The shape returned by `GET /session/:id/message`: message metadata plus
/// its (already accumulated) parts. Also the unit the session store keeps
/// in memory per message.
struct MessageWithParts: Identifiable, Hashable, Decodable {
    var info: MessageInfo
    var parts: [Part]

    var id: String { info.id }
}

// MARK: - Permission

/// A pending approval request: the agent wants to run a tool and is blocked
/// until the user responds via
/// `POST /session/:id/permissions/:permissionID`.
///
/// Wire format note: the published spec models this as `{ id, type,
/// pattern, sessionID, messageID, callID, title, metadata, time }`, but
/// real servers (observed on 1.16.2) emit `{ id, sessionID, permission,
/// patterns, metadata, always, tool: { messageID, callID } }` — no title,
/// different key names, ids nested under `tool`. The decoder accepts both.
struct Permission: Identifiable, Hashable, Decodable {
    let id: String
    /// Permission category (e.g. "bash", "edit", "external_directory").
    var type: String
    var sessionID: String
    var messageID: String?
    var callID: String?
    /// Human-readable description; empty on servers that do not send one
    /// (use `displayTitle` for UI).
    var title: String
    /// Tool-specific details (e.g. the exact command for bash, the file
    /// path for external_directory).
    var metadata: JSONValue?
    /// Glob-like patterns describing the scope of an "always allow" reply.
    var patterns: [String]
    var timeCreated: Double?

    /// Headline for the UI: the server's title when present, otherwise the
    /// permission category.
    var displayTitle: String {
        title.isEmpty ? type : title
    }

    /// The most relevant metadata detail to show the user before they
    /// approve (the command, the file path, ...). Probes the keys the
    /// built-in tools use.
    var detail: String? {
        for key in ["command", "filepath", "filePath", "path", "url", "description"] {
            if let value = metadata?[key]?.stringValue, !value.isEmpty { return value }
        }
        return nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        self.id = try container.decode(String.self, forKey: AnyCodingKey("id"))
        // Spec shape uses "type", real servers use "permission".
        self.type = container.string("type") ?? container.string("permission") ?? ""
        self.sessionID = container.string("sessionID") ?? ""
        // Spec shape has the ids at the top level, real servers nest them
        // under "tool".
        let tool = container.nested("tool")
        self.messageID = container.string("messageID") ?? tool?.string("messageID")
        self.callID = container.string("callID") ?? tool?.string("callID")
        self.title = container.string("title") ?? ""
        self.metadata = container.json("metadata")
        // Real servers send "patterns" (array); the spec shape is
        // "pattern" as either a single string or an array.
        if let patterns = try? container.decodeIfPresent(
            [String].self, forKey: AnyCodingKey("patterns"))
        {
            self.patterns = patterns
        } else {
            switch container.json("pattern") {
            case .string(let value): self.patterns = [value]
            case .array(let values): self.patterns = values.compactMap(\.stringValue)
            default: self.patterns = []
            }
        }
        self.timeCreated = container.nested("time")?.double("created")
    }

    /// Memberwise convenience for tests and previews.
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

/// The three possible replies to a permission request, as accepted by the
/// server: allow this once, allow it permanently, or reject it.
enum PermissionResponse: String, Encodable, CaseIterable {
    case once
    case always
    case reject
}

// MARK: - Session status

/// Whether a session's agent is currently doing something. Sourced from
/// `GET /session/status` (bulk) and `session.status` events (incremental).
enum SessionStatus: Hashable, Decodable {
    case idle
    case busy
    /// The server is waiting to retry a failed model call.
    case retry(attempt: Int?, message: String?)
    /// Forward-compatibility for new status types.
    case unknown(String)

    /// Drives the spinner in the sidebar/chat and the stop button: both
    /// busy and retry mean "the agent has not finished".
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

/// Response of `GET /config/providers`: the configured providers with their
/// models, plus the server's default model per provider.
struct ProvidersResponse: Decodable {
    var providers: [Provider]
    /// Maps providerID → modelID. Named `default` on the wire (a Swift
    /// keyword, hence the rename).
    var defaults: [String: String]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        self.providers =
            (try? container.decodeIfPresent([Provider].self, forKey: AnyCodingKey("providers")))
            ?? []
        self.defaults =
            (try? container.decodeIfPresent([String: String].self, forKey: AnyCodingKey("default")))
            ?? [:]
    }

    init(providers: [Provider], defaults: [String: String]) {
        self.providers = providers
        self.defaults = defaults
    }
}

/// A model provider (Anthropic, OpenAI, ...) and its available models,
/// keyed by model ID.
struct Provider: Identifiable, Hashable, Decodable {
    let id: String
    var name: String
    var models: [String: ModelInfo]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        self.id = try container.decode(String.self, forKey: AnyCodingKey("id"))
        self.name = container.string("name") ?? id
        self.models =
            (try? container.decodeIfPresent(
                [String: ModelInfo].self, forKey: AnyCodingKey("models"))) ?? [:]
    }

    init(id: String, name: String, models: [String: ModelInfo]) {
        self.id = id
        self.name = name
        self.models = models
    }
}

/// The subset of the server's model record the picker needs. The full
/// record (capabilities, cost, limits) is intentionally not modeled.
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

/// An agent definition from `GET /agent` (e.g. "build", "plan", or
/// user-defined agents).
struct Agent: Identifiable, Hashable, Decodable {
    var id: String { name }
    let name: String
    var description: String?
    /// "primary", "subagent", or "all".
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

    /// Subagent-only agents cannot be sent prompts directly, so the picker
    /// excludes them.
    var isSelectable: Bool { mode != "subagent" }
}

// MARK: - Requests

/// Identifies a model by provider + model ID, as the prompt endpoint
/// expects it.
struct ModelRef: Codable, Hashable {
    var providerID: String
    var modelID: String
}

/// Body of `POST /session/:id/prompt_async`. v1 only sends a single text
/// part; the `parts` array mirrors the server's richer input schema so
/// attachments can be added later without reshaping the request.
struct PromptRequest: Encodable {
    struct TextPartInput: Encodable {
        var type = "text"
        var text: String
    }

    /// `nil` lets the server fall back to its configured default model.
    var model: ModelRef?
    /// `nil` lets the server fall back to its default agent.
    var agent: String?
    var parts: [TextPartInput]

    init(text: String, model: ModelRef?, agent: String?) {
        self.model = model
        self.agent = agent
        self.parts = [TextPartInput(text: text)]
    }
}

/// Body of `POST /session`. Both fields optional: an empty body creates a
/// fresh root session and the server picks the title later.
struct CreateSessionRequest: Encodable {
    var parentID: String?
    var title: String?
}

/// Body of `POST /session/:id/permissions/:permissionID`.
struct PermissionReplyRequest: Encodable {
    var response: PermissionResponse
}

// MARK: - Misc responses

/// Response of `GET /global/health`; used by the settings "Test Connection"
/// button and shown to the user (server version).
struct HealthResponse: Decodable {
    var healthy: Bool?
    var version: String?
}

// MARK: - Server events (SSE)

/// Events from the `/event` SSE stream, decoded from
/// `{ "type": "...", "properties": { ... } }` envelopes.
///
/// Only the events the app reacts to get dedicated cases; everything else
/// (LSP, file watcher, TUI, pty, ...) decodes to `.unknown` and is dropped
/// by the store. A dedicated case that fails to decode its payload also
/// degrades to `.unknown` instead of erroring the whole stream.
enum ServerEvent: Decodable {
    /// First event after (re)connecting; triggers a full state re-sync.
    case serverConnected
    case messageUpdated(MessageInfo)
    case messageRemoved(sessionID: String, messageID: String)
    /// A part was created or its content grew/changed. The part carries the
    /// *full* accumulated state (not a delta), so applying it is idempotent.
    case partUpdated(Part)
    case partRemoved(sessionID: String, messageID: String, partID: String)
    case permissionUpdated(Permission)
    /// A permission was answered (possibly by another client, e.g. the TUI).
    case permissionReplied(sessionID: String, permissionID: String)
    case sessionStatus(sessionID: String, status: SessionStatus)
    case sessionIdle(sessionID: String)
    case sessionCreated(Session)
    case sessionUpdated(Session)
    case sessionDeleted(Session)
    case sessionError(sessionID: String?, error: AssistantError?)
    /// Full replacement of a session's todo list. The server emits the
    /// whole array on every update, so the store can swap it in wholesale.
    case todoUpdated(sessionID: String, todos: [TodoItem])
    case unknown(type: String)

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        let type = container.string("type") ?? ""
        let properties = container.nested("properties")

        /// Decodes the `properties` object (or one of its keys) as a typed
        /// value, returning `nil` instead of throwing on failure.
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
        case "permission.updated", "permission.asked":
            // The spec documents "permission.updated"; real servers
            // (observed on 1.16.2) emit "permission.asked". Either way the
            // permission *is* the properties object (not nested under a
            // key).
            if let permission = decodeProperties(Permission.self) {
                self = .permissionUpdated(permission)
            } else {
                self = .unknown(type: type)
            }
        case "permission.replied":
            // Spec says { permissionID, response }; real servers send
            // { requestID, reply }. Accept both.
            self = .permissionReplied(
                sessionID: properties?.string("sessionID") ?? "",
                permissionID: properties?.string("permissionID")
                    ?? properties?.string("requestID") ?? ""
            )
        case "session.status":
            if let status = decodeProperties(SessionStatus.self, "status") {
                self = .sessionStatus(
                    sessionID: properties?.string("sessionID") ?? "", status: status)
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
        case "todo.updated":
            if let todos = decodeProperties([TodoItem].self, "todos") {
                self = .todoUpdated(
                    sessionID: properties?.string("sessionID") ?? "",
                    todos: todos
                )
            } else {
                self = .unknown(type: type)
            }
        default:
            self = .unknown(type: type)
        }
    }
}
