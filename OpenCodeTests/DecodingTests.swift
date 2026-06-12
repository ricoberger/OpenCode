//
//  DecodingTests.swift
//  OpenCodeTests
//
//  Fixture-based tests for the lenient API model decoding. The contract:
//  known shapes decode fully, unknown discriminators decode to `.unknown`,
//  and missing optional fields never throw.
//

import Foundation
import Testing
@testable import OpenCode

@MainActor
struct DecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Session

    @Test func decodesSession() throws {
        let json = """
        {
          "id": "ses_123",
          "projectID": "prj_1",
          "directory": "/Users/rico/project",
          "title": "Fix the build",
          "version": "1.2.3",
          "time": { "created": 1750000000000, "updated": 1750000100000 }
        }
        """
        let session = try decode(Session.self, json)
        #expect(session.id == "ses_123")
        #expect(session.title == "Fix the build")
        #expect(session.parentID == nil)
        #expect(session.timeUpdated == 1_750_000_100_000)
        #expect(session.updatedAt != nil)
    }

    @Test func decodesChildSessionAndEmptyTitle() throws {
        let json = """
        { "id": "ses_child", "parentID": "ses_123", "title": "", "time": { "created": 1, "updated": 2 } }
        """
        let session = try decode(Session.self, json)
        #expect(session.parentID == "ses_123")
        #expect(session.displayTitle == "New Session")
    }

    // MARK: - Messages

    @Test func decodesUserMessage() throws {
        let json = """
        {
          "id": "msg_1",
          "sessionID": "ses_123",
          "role": "user",
          "time": { "created": 1750000000000 },
          "agent": "build",
          "model": { "providerID": "anthropic", "modelID": "claude-sonnet-4-5" }
        }
        """
        let message = try decode(MessageInfo.self, json)
        #expect(message.role == .user)
        #expect(message.providerID == "anthropic")
        #expect(message.modelID == "claude-sonnet-4-5")
        #expect(message.agent == "build")
    }

    @Test func decodesAssistantMessageWithError() throws {
        let json = """
        {
          "id": "msg_2",
          "sessionID": "ses_123",
          "role": "assistant",
          "time": { "created": 1750000000000, "completed": 1750000005000 },
          "parentID": "msg_1",
          "modelID": "claude-sonnet-4-5",
          "providerID": "anthropic",
          "mode": "build",
          "cost": 0.01,
          "error": { "name": "APIError", "data": { "message": "rate limited", "isRetryable": true } }
        }
        """
        let message = try decode(MessageInfo.self, json)
        #expect(message.role == .assistant)
        #expect(message.isCompleted)
        #expect(message.error?.name == "APIError")
        #expect(message.error?.displayMessage == "rate limited")
        #expect(message.error?.isAbort == false)
    }

    @Test func abortErrorIsRecognized() throws {
        let json = """
        {
          "id": "msg_3",
          "sessionID": "ses_123",
          "role": "assistant",
          "time": { "created": 1 },
          "error": { "name": "MessageAbortedError", "data": { "message": "aborted" } }
        }
        """
        let message = try decode(MessageInfo.self, json)
        #expect(message.error?.isAbort == true)
    }

    @Test func unknownRoleDecodesLeniently() throws {
        let json = """
        { "id": "msg_4", "sessionID": "ses_123", "role": "system-something-new", "time": { "created": 1 } }
        """
        let message = try decode(MessageInfo.self, json)
        #expect(message.role == .unknown)
    }

    // MARK: - Parts

    @Test func decodesTextPart() throws {
        let json = """
        { "id": "prt_1", "sessionID": "ses_1", "messageID": "msg_1", "type": "text", "text": "Hello **world**" }
        """
        let part = try decode(Part.self, json)
        guard case .text(let data) = part.content else {
            Issue.record("expected text part")
            return
        }
        #expect(data.text == "Hello **world**")
        #expect(!data.synthetic)
    }

    @Test func decodesReasoningPart() throws {
        let json = """
        {
          "id": "prt_2", "sessionID": "ses_1", "messageID": "msg_1",
          "type": "reasoning", "text": "thinking hard",
          "time": { "start": 1750000000000 }
        }
        """
        let part = try decode(Part.self, json)
        guard case .reasoning(let data) = part.content else {
            Issue.record("expected reasoning part")
            return
        }
        #expect(data.text == "thinking hard")
        #expect(data.timeEnd == nil)
    }

    @Test func decodesRunningToolPart() throws {
        let json = """
        {
          "id": "prt_3", "sessionID": "ses_1", "messageID": "msg_1",
          "type": "tool", "callID": "call_1", "tool": "bash",
          "state": {
            "status": "running",
            "input": { "command": "swift build", "timeout": 120 },
            "time": { "start": 1750000000000 }
          }
        }
        """
        let part = try decode(Part.self, json)
        guard case .tool(let data) = part.content else {
            Issue.record("expected tool part")
            return
        }
        #expect(data.tool == "bash")
        #expect(data.status == .running)
        #expect(data.summary == "swift build")
        #expect(data.output == nil)
    }

    @Test func decodesCompletedToolPart() throws {
        let json = """
        {
          "id": "prt_4", "sessionID": "ses_1", "messageID": "msg_1",
          "type": "tool", "callID": "call_2", "tool": "read",
          "state": {
            "status": "completed",
            "input": { "filePath": "/tmp/a.swift" },
            "output": "let a = 1",
            "title": "/tmp/a.swift",
            "metadata": {},
            "time": { "start": 1, "end": 2 }
          }
        }
        """
        let part = try decode(Part.self, json)
        guard case .tool(let data) = part.content else {
            Issue.record("expected tool part")
            return
        }
        #expect(data.status == .completed)
        #expect(data.output == "let a = 1")
        #expect(data.summary == "/tmp/a.swift")
    }

    @Test func decodesErrorToolPartAndUnknownStatus() throws {
        let errorJSON = """
        {
          "id": "prt_5", "sessionID": "ses_1", "messageID": "msg_1",
          "type": "tool", "tool": "bash",
          "state": { "status": "error", "input": {}, "error": "exit 1", "time": { "start": 1, "end": 2 } }
        }
        """
        let errorPart = try decode(Part.self, errorJSON)
        guard case .tool(let errorData) = errorPart.content else {
            Issue.record("expected tool part")
            return
        }
        #expect(errorData.status == .error)
        #expect(errorData.errorMessage == "exit 1")

        let unknownStatusJSON = """
        {
          "id": "prt_6", "sessionID": "ses_1", "messageID": "msg_1",
          "type": "tool", "tool": "bash",
          "state": { "status": "paused-new-state", "input": {} }
        }
        """
        let unknownPart = try decode(Part.self, unknownStatusJSON)
        guard case .tool(let unknownData) = unknownPart.content else {
            Issue.record("expected tool part")
            return
        }
        #expect(unknownData.status == .unknown)
    }

    @Test func decodesStructuralAndFileParts() throws {
        let stepStart = try decode(
            Part.self,
            #"{ "id": "p1", "sessionID": "s", "messageID": "m", "type": "step-start" }"#
        )
        #expect(stepStart.content == .stepStart)

        let patch = try decode(
            Part.self,
            #"{ "id": "p2", "sessionID": "s", "messageID": "m", "type": "patch", "hash": "abc", "files": ["a.swift"] }"#
        )
        #expect(patch.content == .patch(files: ["a.swift"]))

        let file = try decode(
            Part.self,
            #"{ "id": "p3", "sessionID": "s", "messageID": "m", "type": "file", "mime": "image/png", "filename": "shot.png", "url": "data:..." }"#
        )
        guard case .file(let data) = file.content else {
            Issue.record("expected file part")
            return
        }
        #expect(data.filename == "shot.png")
    }

    @Test func unknownPartTypeNeverThrows() throws {
        let json = """
        {
          "id": "prt_new", "sessionID": "ses_1", "messageID": "msg_1",
          "type": "holographic-diff", "payload": { "nested": [1, 2, 3] }
        }
        """
        let part = try decode(Part.self, json)
        #expect(part.content == .unknown(type: "holographic-diff"))
        #expect(part.id == "prt_new")
    }

    @Test func decodesMessagesListEnvelope() throws {
        let json = """
        [
          {
            "info": { "id": "msg_1", "sessionID": "ses_1", "role": "user", "time": { "created": 1 } },
            "parts": [
              { "id": "p1", "sessionID": "ses_1", "messageID": "msg_1", "type": "text", "text": "hi" },
              { "id": "p2", "sessionID": "ses_1", "messageID": "msg_1", "type": "brand-new-thing" }
            ]
          }
        ]
        """
        let messages = try decode([MessageWithParts].self, json)
        #expect(messages.count == 1)
        #expect(messages[0].parts.count == 2)
        #expect(messages[0].parts[1].content == .unknown(type: "brand-new-thing"))
    }

    // MARK: - Permission

    @Test func decodesPermissionWithStringAndArrayPatterns() throws {
        let stringPattern = """
        {
          "id": "per_1", "type": "bash", "pattern": "rm *",
          "sessionID": "ses_1", "messageID": "msg_1", "callID": "call_1",
          "title": "Run rm -rf build", "metadata": { "command": "rm -rf build" },
          "time": { "created": 1750000000000 }
        }
        """
        let permission = try decode(Permission.self, stringPattern)
        #expect(permission.patterns == ["rm *"])
        #expect(permission.title == "Run rm -rf build")

        let arrayPattern = """
        { "id": "per_2", "type": "edit", "pattern": ["src/*", "tests/*"], "sessionID": "ses_1", "messageID": "m", "title": "Edit files", "metadata": {}, "time": { "created": 1 } }
        """
        let permission2 = try decode(Permission.self, arrayPattern)
        #expect(permission2.patterns == ["src/*", "tests/*"])
    }

    // MARK: - Status, providers, agents

    @Test func decodesSessionStatusMap() throws {
        let json = """
        {
          "ses_1": { "type": "idle" },
          "ses_2": { "type": "busy" },
          "ses_3": { "type": "retry", "attempt": 2, "message": "overloaded", "next": 123 },
          "ses_4": { "type": "hyperspace" }
        }
        """
        let statuses = try decode([String: SessionStatus].self, json)
        #expect(statuses["ses_1"] == .idle)
        #expect(statuses["ses_2"]?.isWorking == true)
        #expect(statuses["ses_3"] == .retry(attempt: 2, message: "overloaded"))
        #expect(statuses["ses_4"] == .unknown("hyperspace"))
        #expect(statuses["ses_4"]?.isWorking == false)
    }

    @Test func decodesProvidersResponse() throws {
        let json = """
        {
          "providers": [
            {
              "id": "anthropic",
              "name": "Anthropic",
              "source": "env",
              "env": [],
              "options": {},
              "models": {
                "claude-sonnet-4-5": { "id": "claude-sonnet-4-5", "name": "Claude Sonnet 4.5", "status": "active" }
              }
            }
          ],
          "default": { "anthropic": "claude-sonnet-4-5" }
        }
        """
        let response = try decode(ProvidersResponse.self, json)
        #expect(response.providers.count == 1)
        #expect(response.providers[0].models["claude-sonnet-4-5"]?.name == "Claude Sonnet 4.5")
        #expect(response.defaults["anthropic"] == "claude-sonnet-4-5")
    }

    @Test func decodesAgents() throws {
        let json = """
        [
          { "name": "build", "mode": "primary", "builtIn": true, "permission": { "edit": "allow", "bash": {} }, "tools": {}, "options": {} },
          { "name": "explore", "description": "Read-only", "mode": "subagent", "builtIn": true, "permission": { "edit": "deny", "bash": {} }, "tools": {}, "options": {} }
        ]
        """
        let agents = try decode([Agent].self, json)
        #expect(agents.count == 2)
        #expect(agents[0].isSelectable)
        #expect(!agents[1].isSelectable)
    }

    // MARK: - Events

    @Test func decodesPartUpdatedEvent() throws {
        let json = """
        {
          "type": "message.part.updated",
          "properties": {
            "part": { "id": "p1", "sessionID": "s1", "messageID": "m1", "type": "text", "text": "Hel" },
            "delta": "l"
          }
        }
        """
        let event = try decode(ServerEvent.self, json)
        guard case .partUpdated(let part) = event else {
            Issue.record("expected partUpdated")
            return
        }
        #expect(part.id == "p1")
        guard case .text(let data) = part.content else {
            Issue.record("expected text content")
            return
        }
        #expect(data.text == "Hel")
    }

    @Test func decodesPermissionAndSessionEvents() throws {
        let permissionEvent = try decode(ServerEvent.self, """
        {
          "type": "permission.updated",
          "properties": {
            "id": "per_1", "type": "bash", "sessionID": "ses_1", "messageID": "m1",
            "title": "Run command", "metadata": {}, "time": { "created": 1 }
          }
        }
        """)
        guard case .permissionUpdated(let permission) = permissionEvent else {
            Issue.record("expected permissionUpdated")
            return
        }
        #expect(permission.id == "per_1")

        let statusEvent = try decode(ServerEvent.self, """
        { "type": "session.status", "properties": { "sessionID": "ses_1", "status": { "type": "busy" } } }
        """)
        guard case .sessionStatus(let sessionID, let status) = statusEvent else {
            Issue.record("expected sessionStatus")
            return
        }
        #expect(sessionID == "ses_1")
        #expect(status == .busy)

        let idleEvent = try decode(ServerEvent.self, """
        { "type": "session.idle", "properties": { "sessionID": "ses_1" } }
        """)
        guard case .sessionIdle("ses_1") = idleEvent else {
            Issue.record("expected sessionIdle")
            return
        }
    }

    @Test func unknownEventTypeNeverThrows() throws {
        let json = """
        { "type": "quantum.entanglement.updated", "properties": { "whatever": true } }
        """
        let event = try decode(ServerEvent.self, json)
        guard case .unknown(let type) = event else {
            Issue.record("expected unknown event")
            return
        }
        #expect(type == "quantum.entanglement.updated")
    }
}
