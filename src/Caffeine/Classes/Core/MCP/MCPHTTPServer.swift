//
//  MCPHTTPServer.swift
//  Caffeine Plus
//

import Foundation
import Network
import Security

/// Loopback-only HTTP endpoint (`POST /mcp`) protected by a bearer token.
final class MCPHTTPServer {
    static let defaultPort: UInt16 = 47821
    private static let maxRequestSize = 1 << 20

    private let port: UInt16
    private let token: String
    private let handler: @Sendable (Data) async -> Data?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "caffeineplus.mcp")

    init(port: UInt16 = MCPHTTPServer.defaultPort, token: String, handler: @escaping @Sendable (Data) async -> Data?) {
        self.port = port
        self.token = token
        self.handler = handler
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: self.queue)
        self.listener = listener
    }

    func stop() {
        self.listener?.cancel()
        self.listener = nil
    }

    // MARK: Token

    /// Reads or creates the token file (0600).
    static func loadOrCreateToken(at url: URL = AppPaths.supportDirectory.appendingPathComponent("mcp-token")) -> String {
        if let existing = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), existing.count >= 32
        {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: url.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
        return token
    }

    // MARK: Connection

    private func accept(_ connection: NWConnection) {
        connection.start(queue: self.queue)
        self.receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count > Self.maxRequestSize {
                return self.send(connection, status: 413, body: nil)
            }
            if let request = HTTPRequest(parsing: buffer) {
                return self.respond(to: request, on: connection)
            }
            if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) {
        guard request.path == "/mcp" else { return self.send(connection, status: 404, body: nil) }
        if let host = request.headers["host"], !Self.isLoopbackHost(host) {
            return self.send(connection, status: 403, body: nil)
        }
        if let origin = request.headers["origin"], !Self.isLoopbackHost(origin) {
            return self.send(connection, status: 403, body: nil)
        }
        guard request.headers["authorization"] == "Bearer \(self.token)" else {
            return self.send(connection, status: 401, body: nil)
        }
        guard request.method == "POST" else { return self.send(connection, status: 405, body: nil) }

        let handler = self.handler
        Task {
            let response = await handler(request.body)
            self.send(connection, status: response == nil ? 202 : 200, body: response)
        }
    }

    private func send(_ connection: NWConnection, status: Int, body: Data?) {
        let reason = [200: "OK", 202: "Accepted", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                      405: "Method Not Allowed", 413: "Payload Too Large"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nContent-Length: \(body?.count ?? 0)\r\n"
        if status == 405 { head += "Allow: POST\r\n" }
        if body != nil { head += "Content-Type: application/json\r\n" }
        head += "\r\n"
        var payload = Data(head.utf8)
        if let body { payload.append(body) }
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }

    static func isLoopbackHost(_ value: String) -> Bool {
        var text = value.lowercased()
        for prefix in ["http://", "https://"] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        let host = text.split(separator: ":", maxSplits: 1).first.map(String.init) ?? text
        return ["127.0.0.1", "localhost", "[::1]"].contains(host)
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    /// Returns nil until the whole request (headers + Content-Length bytes) is available.
    init?(parsing data: Data) {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<separator.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[separator.upperBound...]
        guard body.count >= length else { return nil }
        self.method = String(parts[0])
        self.path = String(parts[1])
        self.headers = headers
        self.body = Data(body.prefix(length))
    }
}
