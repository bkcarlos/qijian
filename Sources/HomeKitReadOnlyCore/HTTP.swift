import Foundation

public struct HTTPRequest {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data
}

public enum HTTPFailure: Error, Equatable {
    case rejected(Int, String)
}

/// Deliberately bounded HTTP/1.1 subset: one Content-Length request per connection.
/// No chunked requests, pipelining, proxying, or browser CORS access.
public enum HTTPParser {
    public static let maxHeaderBytes = 16_384
    public static let maxBodyBytes = 1_048_576

    public static func parse(_ data: Data) throws -> HTTPRequest? {
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > maxHeaderBytes { throw HTTPFailure.rejected(431, "Headers too large") }
            return nil
        }
        guard boundary.lowerBound <= maxHeaderBytes,
              let head = String(data: data[..<boundary.lowerBound], encoding: .utf8) else {
            throw HTTPFailure.rejected(400, "Invalid headers")
        }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[2] == "HTTP/1.1" else {
            throw HTTPFailure.rejected(400, "Expected HTTP/1.1")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else {
                throw HTTPFailure.rejected(400, "Malformed header")
            }
            let key = String(line[..<colon]).lowercased()
            guard !key.isEmpty, key.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  headers[key] == nil else { throw HTTPFailure.rejected(400, "Invalid or duplicate header") }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.contains("\r"), !value.contains("\n") else { throw HTTPFailure.rejected(400, "Invalid header value") }
            headers[key] = value
        }
        guard headers["transfer-encoding"] == nil else { throw HTTPFailure.rejected(400, "Chunked requests are not supported") }
        let rawLength = headers["content-length"] ?? "0"
        guard !rawLength.isEmpty, rawLength.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int(rawLength) else {
            throw HTTPFailure.rejected(400, "Invalid Content-Length")
        }
        guard length <= maxBodyBytes else { throw HTTPFailure.rejected(413, "Body too large") }
        let end = boundary.upperBound + length
        guard data.count >= end else { return nil }
        guard data.count == end else { throw HTTPFailure.rejected(400, "Pipelining is not supported") }
        return HTTPRequest(method: String(first[0]), path: String(first[1]), headers: headers, body: Data(data[boundary.upperBound..<end]))
    }
}

public struct HTTPPolicy {
    public let port: UInt16
    public let token: String
    public let controlToken: String?
    public init(port: UInt16, token: String, controlToken: String? = nil) { self.port = port; self.token = token; self.controlToken = controlToken }

    public func validate(_ request: HTTPRequest) throws {
        _ = try authorize(request)
    }

    public func authorize(_ request: HTTPRequest) throws -> AccessRole {
        guard ["127.0.0.1:\(port)", "localhost:\(port)"].contains(request.headers["host"] ?? "") else {
            throw HTTPFailure.rejected(403, "Invalid Host")
        }
        if let origin = request.headers["origin"], !["http://127.0.0.1:\(port)", "http://localhost:\(port)"].contains(origin) {
            throw HTTPFailure.rejected(403, "Invalid Origin")
        }
        let header = request.headers["authorization"] ?? ""
        let read = secureEqual(header, "Bearer \(token)")
        let control = controlToken.map { secureEqual(header, "Bearer \($0)") } ?? false
        guard read || control else {
            throw HTTPFailure.rejected(401, "Bearer token required")
        }
        guard request.path == "/mcp" else { throw HTTPFailure.rejected(404, "Not found") }
        guard request.method == "POST" else { throw HTTPFailure.rejected(405, "Only POST is supported; no SSE stream or sessions") }
        guard request.headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else {
            throw HTTPFailure.rejected(415, "Expected application/json")
        }
        let accept = request.headers["accept"] ?? ""
        guard accept.contains("application/json"), accept.contains("text/event-stream") else {
            throw HTTPFailure.rejected(406, "Accept must include application/json and text/event-stream")
        }
        if let version = request.headers["mcp-protocol-version"], !MCPRouter.versions.contains(version) {
            throw HTTPFailure.rejected(400, "Unsupported MCP protocol version")
        }
        return read ? .read : .control
    }

    private func secureEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
