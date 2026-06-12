//
//  SSE.swift
//  OpenCode
//
//  Server-sent events: an incremental parser plus a stream of decoded
//  `ServerEvent`s from the opencode server's `/event` endpoint.
//
//  This is the app's real-time backbone. One stream per app (the endpoint
//  is server-wide) pushes everything: streaming message parts, session
//  list changes, status changes, and permission prompts. Prompts are sent
//  fire-and-forget via REST; all results arrive here.
//
//  Hand-rolled instead of using an SSE library: the format is ~50 lines to
//  parse, and owning the parser lets the tests exercise the nasty cases
//  (chunk boundaries, CRLF, multi-line data).
//

import Foundation

// MARK: - Parser

/// Incremental parser for the `text/event-stream` format. Feed it arbitrary
/// string chunks; it returns the `data` payloads of all events completed by
/// that chunk. Handles events split across chunk boundaries, CRLF line
/// endings, multi-line `data:` fields, and comment lines.
///
/// Kept as a pure value type with no I/O so unit tests can drive it with
/// scripted chunks.
struct SSEParser {
    /// Unterminated tail of the input — everything after the last newline
    /// seen so far. Grows until the next chunk completes the line.
    private var pendingLine = ""
    /// `data:` payloads of the event currently being assembled. Per the SSE
    /// spec, multiple data lines belong to one event until a blank line
    /// terminates it.
    private var dataLines: [String] = []

    mutating func consume(_ chunk: String) -> [String] {
        var completedEvents: [String] = []
        pendingLine += chunk

        // Split on unicode scalars: in Swift, "\r\n" is a single Character,
        // so a character-level search for "\n" would miss CRLF line endings.
        while let newlineIndex = pendingLine.unicodeScalars.firstIndex(of: "\n") {
            let scalars = pendingLine.unicodeScalars
            var line = String(Substring(scalars[..<newlineIndex]))
            pendingLine = String(Substring(scalars[scalars.index(after: newlineIndex)...]))

            // Strip the carriage return of CRLF line endings.
            if line.hasSuffix("\r") {
                line.removeLast()
            }

            if line.isEmpty {
                // Blank line = event boundary. Dispatch the accumulated
                // payload (if any; lone blank lines are keep-alives).
                if !dataLines.isEmpty {
                    completedEvents.append(dataLines.joined(separator: "\n"))
                    dataLines = []
                }
            } else if line.hasPrefix("data:") {
                var payload = String(line.dropFirst("data:".count))
                // The spec allows exactly one optional space after the colon.
                if payload.hasPrefix(" ") {
                    payload.removeFirst()
                }
                dataLines.append(payload)
            }
            // Other fields (event:, id:, retry:) and comments (:) are
            // ignored — opencode only uses data-only events.
        }

        return completedEvents
    }
}

// MARK: - Event stream

enum EventStream {
    /// Connects to `/event` and yields decoded events until the connection
    /// drops (throws) or the stream is cancelled. Undecodable events are
    /// skipped; `ServerEvent`'s lenient decoding maps unknown types to
    /// `.unknown` so this only happens for malformed payloads.
    ///
    /// The stream never ends normally: a server-side close is converted to
    /// an error so `ServerConnection`'s reconnect loop always takes over.
    static func connect(config: ServerConfig) -> AsyncThrowingStream<ServerEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                // A dedicated session: the streaming request must not be
                // subject to the 15s REST timeout, so it gets effectively
                // unlimited timeouts (1 day idle / 7 days total).
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 86_400
                configuration.timeoutIntervalForResource = 86_400 * 7
                let session = URLSession(configuration: configuration)
                defer { session.invalidateAndCancel() }

                var url = config.baseURL
                url.append(path: "/event")

                var request = URLRequest(url: url)
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                if let authorization = config.authorizationHeader {
                    request.setValue(authorization, forHTTPHeaderField: "Authorization")
                }

                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw APIError.notHTTP
                    }
                    guard http.statusCode == 200 else {
                        throw APIError.http(status: http.statusCode, message: nil)
                    }

                    var parser = SSEParser()
                    var lineBuffer = Data()
                    let decoder = JSONDecoder()

                    // Feed the parser whole lines: buffer raw bytes and
                    // flush on "\n". Flushing only at newlines also
                    // guarantees we never split a multi-byte UTF-8 sequence
                    // (a "\n" byte can't occur inside one).
                    for try await byte in bytes {
                        lineBuffer.append(byte)
                        guard byte == UInt8(ascii: "\n") else { continue }

                        let chunk = String(decoding: lineBuffer, as: UTF8.self)
                        lineBuffer.removeAll(keepingCapacity: true)

                        for payload in parser.consume(chunk) {
                            // Skip undecodable payloads instead of killing
                            // the stream — one bad event must not cost the
                            // connection.
                            if let event = try? decoder.decode(
                                ServerEvent.self, from: Data(payload.utf8))
                            {
                                continuation.yield(event)
                            }
                        }
                    }

                    // The server closed the stream; surface it as an error so
                    // the connection layer reconnects.
                    throw URLError(.networkConnectionLost)
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            // Tearing down the stream (e.g. app backgrounded, config
            // changed) cancels the network task.
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
