//
//  SessionStoreTests.swift
//  OpenCodeTests
//
//  Applies scripted event sequences to the store and asserts the resulting
//  state: ordering, streaming part updates, out-of-order arrival, and the
//  permission lifecycle.
//

import Foundation
import Testing
@testable import OpenCode

@MainActor
struct SessionStoreTests {
    private func makeStore() -> SessionStore {
        SessionStore(connection: ServerConnection())
    }

    private func event(_ json: String) throws -> ServerEvent {
        try JSONDecoder().decode(ServerEvent.self, from: Data(json.utf8))
    }

    // MARK: - Sessions

    @Test func sessionCreatedUpsertsAndSortsByUpdateTime() throws {
        let store = makeStore()

        store.apply(try event("""
        { "type": "session.created", "properties": { "info": { "id": "ses_old", "title": "Old", "time": { "created": 1, "updated": 100 } } } }
        """))
        store.apply(try event("""
        { "type": "session.created", "properties": { "info": { "id": "ses_new", "title": "New", "time": { "created": 2, "updated": 200 } } } }
        """))

        #expect(store.sessions.map(\.id) == ["ses_new", "ses_old"])

        // Updating the old session moves it to the top.
        store.apply(try event("""
        { "type": "session.updated", "properties": { "info": { "id": "ses_old", "title": "Old", "time": { "created": 1, "updated": 300 } } } }
        """))
        #expect(store.sessions.map(\.id) == ["ses_old", "ses_new"])
        #expect(store.sessions.count == 2)
    }

    @Test func childSessionsAreIgnored() throws {
        let store = makeStore()
        store.apply(try event("""
        { "type": "session.created", "properties": { "info": { "id": "ses_child", "parentID": "ses_root", "title": "Subagent", "time": { "created": 1, "updated": 1 } } } }
        """))
        #expect(store.sessions.isEmpty)
    }

    @Test func sessionDeletedCleansAllState() throws {
        let store = makeStore()
        store.apply(try event("""
        { "type": "session.created", "properties": { "info": { "id": "ses_1", "title": "T", "time": { "created": 1, "updated": 1 } } } }
        """))
        store.apply(try event("""
        { "type": "message.updated", "properties": { "info": { "id": "msg_1", "sessionID": "ses_1", "role": "user", "time": { "created": 1 } } } }
        """))
        store.apply(try event("""
        { "type": "session.status", "properties": { "sessionID": "ses_1", "status": { "type": "busy" } } }
        """))

        store.apply(try event("""
        { "type": "session.deleted", "properties": { "info": { "id": "ses_1", "title": "T", "time": { "created": 1, "updated": 1 } } } }
        """))

        #expect(store.sessions.isEmpty)
        #expect(store.messages(for: "ses_1").isEmpty)
        #expect(store.status(for: "ses_1") == .idle)
    }

    // MARK: - Messages and streaming parts

    @Test func streamingTextPartReplacesById() throws {
        let store = makeStore()
        store.apply(try event("""
        { "type": "message.updated", "properties": { "info": { "id": "msg_1", "sessionID": "ses_1", "role": "assistant", "time": { "created": 1 } } } }
        """))

        store.apply(try event("""
        { "type": "message.part.updated", "properties": { "part": { "id": "p1", "sessionID": "ses_1", "messageID": "msg_1", "type": "text", "text": "Hel" } } }
        """))
        store.apply(try event("""
        { "type": "message.part.updated", "properties": { "part": { "id": "p1", "sessionID": "ses_1", "messageID": "msg_1", "type": "text", "text": "Hello world" } } }
        """))

        let messages = store.messages(for: "ses_1")
        #expect(messages.count == 1)
        #expect(messages[0].parts.count == 1)
        guard case .text(let data) = messages[0].parts[0].content else {
            Issue.record("expected text part")
            return
        }
        #expect(data.text == "Hello world")
    }

    @Test func partArrivingBeforeMessageCreatesPlaceholderThenInfoFillsIn() throws {
        let store = makeStore()

        store.apply(try event("""
        { "type": "message.part.updated", "properties": { "part": { "id": "p1", "sessionID": "ses_1", "messageID": "msg_1", "type": "text", "text": "early" } } }
        """))

        var messages = store.messages(for: "ses_1")
        #expect(messages.count == 1)
        #expect(messages[0].parts.count == 1)

        store.apply(try event("""
        { "type": "message.updated", "properties": { "info": { "id": "msg_1", "sessionID": "ses_1", "role": "assistant", "time": { "created": 42 } } } }
        """))

        messages = store.messages(for: "ses_1")
        #expect(messages.count == 1)
        #expect(messages[0].info.timeCreated == 42)
        #expect(messages[0].parts.count == 1, "filling in message info must not drop parts")
    }

    @Test func toolPartStatusProgressionAndRemoval() throws {
        let store = makeStore()
        store.apply(try event("""
        { "type": "message.updated", "properties": { "info": { "id": "msg_1", "sessionID": "ses_1", "role": "assistant", "time": { "created": 1 } } } }
        """))
        store.apply(try event("""
        { "type": "message.part.updated", "properties": { "part": { "id": "p1", "sessionID": "ses_1", "messageID": "msg_1", "type": "tool", "tool": "bash", "state": { "status": "running", "input": { "command": "ls" } } } } }
        """))
        store.apply(try event("""
        { "type": "message.part.updated", "properties": { "part": { "id": "p1", "sessionID": "ses_1", "messageID": "msg_1", "type": "tool", "tool": "bash", "state": { "status": "completed", "input": { "command": "ls" }, "output": "a b c", "title": "ls", "metadata": {}, "time": { "start": 1, "end": 2 } } } } }
        """))

        var parts = store.messages(for: "ses_1")[0].parts
        #expect(parts.count == 1)
        guard case .tool(let data) = parts[0].content else {
            Issue.record("expected tool part")
            return
        }
        #expect(data.status == .completed)
        #expect(data.output == "a b c")

        store.apply(try event("""
        { "type": "message.part.removed", "properties": { "sessionID": "ses_1", "messageID": "msg_1", "partID": "p1" } }
        """))
        parts = store.messages(for: "ses_1")[0].parts
        #expect(parts.isEmpty)
    }

    @Test func messageRemovedDeletesMessage() throws {
        let store = makeStore()
        store.apply(try event("""
        { "type": "message.updated", "properties": { "info": { "id": "msg_1", "sessionID": "ses_1", "role": "user", "time": { "created": 1 } } } }
        """))
        store.apply(try event("""
        { "type": "message.removed", "properties": { "sessionID": "ses_1", "messageID": "msg_1" } }
        """))
        #expect(store.messages(for: "ses_1").isEmpty)
    }

    // MARK: - Permissions

    @Test func permissionLifecycle() throws {
        let store = makeStore()

        store.apply(try event("""
        { "type": "permission.updated", "properties": { "id": "per_1", "type": "bash", "sessionID": "ses_1", "messageID": "msg_1", "title": "Run ls", "metadata": {}, "time": { "created": 1 } } }
        """))
        #expect(store.permissions(for: "ses_1").count == 1)

        // Same permission updated again: replaced, not duplicated.
        store.apply(try event("""
        { "type": "permission.updated", "properties": { "id": "per_1", "type": "bash", "sessionID": "ses_1", "messageID": "msg_1", "title": "Run ls -la", "metadata": {}, "time": { "created": 1 } } }
        """))
        #expect(store.permissions(for: "ses_1").count == 1)
        #expect(store.permissions(for: "ses_1")[0].title == "Run ls -la")

        store.apply(try event("""
        { "type": "permission.replied", "properties": { "sessionID": "ses_1", "permissionID": "per_1", "response": "once" } }
        """))
        #expect(store.permissions(for: "ses_1").isEmpty)
    }

    // MARK: - Status and errors

    @Test func statusEventsUpdateWorkingState() throws {
        let store = makeStore()
        #expect(store.status(for: "ses_1") == .idle)

        store.apply(try event("""
        { "type": "session.status", "properties": { "sessionID": "ses_1", "status": { "type": "busy" } } }
        """))
        #expect(store.status(for: "ses_1").isWorking)

        store.apply(try event("""
        { "type": "session.idle", "properties": { "sessionID": "ses_1" } }
        """))
        #expect(!store.status(for: "ses_1").isWorking)
    }

    @Test func sessionErrorSetsBannerButAbortIsSuppressed() throws {
        let store = makeStore()

        store.apply(try event("""
        { "type": "session.error", "properties": { "sessionID": "ses_1", "error": { "name": "MessageAbortedError", "data": { "message": "aborted" } } } }
        """))
        #expect(store.lastError == nil)

        store.apply(try event("""
        { "type": "session.error", "properties": { "sessionID": "ses_1", "error": { "name": "APIError", "data": { "message": "boom" } } } }
        """))
        #expect(store.lastError == "boom")
    }

    @Test func unknownEventsAreNoOps() throws {
        let store = makeStore()
        store.apply(try event("""
        { "type": "totally.new.event", "properties": { "x": 1 } }
        """))
        #expect(store.sessions.isEmpty)
        #expect(store.lastError == nil)
    }
}
