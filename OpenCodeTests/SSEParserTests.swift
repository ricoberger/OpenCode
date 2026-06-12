//
//  SSEParserTests.swift
//  OpenCodeTests
//
//  The parser must survive events split across arbitrary chunk boundaries,
//  CRLF line endings, multi-line data fields, and ignore non-data fields.
//

import Testing
@testable import OpenCode

@MainActor
struct SSEParserTests {
    @Test func parsesSingleEvent() {
        var parser = SSEParser()
        let events = parser.consume("data: {\"type\":\"session.idle\"}\n\n")
        #expect(events == ["{\"type\":\"session.idle\"}"])
    }

    @Test func parsesEventSplitAcrossChunks() {
        var parser = SSEParser()
        var events: [String] = []
        events += parser.consume("data: {\"type\":\"mess")
        #expect(events.isEmpty)
        events += parser.consume("age.updated\"}")
        #expect(events.isEmpty)
        events += parser.consume("\n")
        #expect(events.isEmpty)
        events += parser.consume("\n")
        #expect(events == ["{\"type\":\"message.updated\"}"])
    }

    @Test func parsesMultipleEventsInOneChunk() {
        var parser = SSEParser()
        let events = parser.consume("data: one\n\ndata: two\n\ndata: thr")
        #expect(events == ["one", "two"])
        var remaining = parser
        #expect(remaining.consume("ee\n\n") == ["three"])
    }

    @Test func joinsMultiLineDataFields() {
        var parser = SSEParser()
        let events = parser.consume("data: line1\ndata: line2\n\n")
        #expect(events == ["line1\nline2"])
    }

    @Test func handlesCRLF() {
        var parser = SSEParser()
        let events = parser.consume("data: payload\r\n\r\n")
        #expect(events == ["payload"])
    }

    @Test func handlesDataWithoutSpace() {
        var parser = SSEParser()
        let events = parser.consume("data:{\"a\":1}\n\n")
        #expect(events == ["{\"a\":1}"])
    }

    @Test func ignoresCommentsAndOtherFields() {
        var parser = SSEParser()
        let events = parser.consume(": heartbeat\nevent: message\nid: 42\nretry: 1000\ndata: payload\n\n")
        #expect(events == ["payload"])
    }

    @Test func blankLinesWithoutDataProduceNothing() {
        var parser = SSEParser()
        let events = parser.consume("\n\n: ping\n\n\n")
        #expect(events.isEmpty)
    }

    @Test func byteByByteDelivery() {
        var parser = SSEParser()
        var events: [String] = []
        for character in "data: {\"x\":true}\n\n" {
            events += parser.consume(String(character))
        }
        #expect(events == ["{\"x\":true}"])
    }
}
