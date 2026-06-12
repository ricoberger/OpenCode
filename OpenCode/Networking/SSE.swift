//
//  SSE.swift
//  OpenCode
//
//  Server-sent events: an incremental parser plus a stream of decoded
//  `ServerEvent`s from the opencode server's `/event` endpoint.
//

import Foundation

// MARK: - Parser

/// Incremental parser for the `text/event-stream` format. Feed it arbitrary
/// string chunks; it returns the `data` payloads of all events completed by
/// that chunk. Handles events split across chunk boundaries, CRLF line
/// endings, multi-line `data:` fields, and comment lines.
struct SSEParser {
    private var pendingLine = ""
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

            if line.hasSuffix("\r") {
                line.removeLast()
            }

            if line.isEmpty {
                if !dataLines.isEmpty {
                    completedEvents.append(dataLines.joined(separator: "\n"))
                    dataLines = []
                }
            } else if line.hasPrefix("data:") {
                var payload = String(line.dropFirst("data:".count))
                if payload.hasPrefix(" ") {
                    payload.removeFirst()
                }
                dataLines.append(payload)
            }
            // Other fields (event:, id:, retry:) and comments (:) are ignored.
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
    static func connect(config: ServerConfig) -> AsyncThrowingStream<ServerEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
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

                    for try await byte in bytes {
                        lineBuffer.append(byte)
                        guard byte == UInt8(ascii: "\n") else { continue }

                        let chunk = String(decoding: lineBuffer, as: UTF8.self)
                        lineBuffer.removeAll(keepingCapacity: true)

                        for payload in parser.consume(chunk) {
                            if let event = try? decoder.decode(ServerEvent.self, from: Data(payload.utf8)) {
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

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
