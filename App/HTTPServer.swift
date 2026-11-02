import Foundation
import Network
import Security

/// Private token file in this app's sandbox; never placed in the repo or logs.
enum LocalCredential {
    static func loadOrCreate(control: Bool = false) throws -> (token: String, path: String) {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("HomeKitReadOnly", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let url = directory.appendingPathComponent(control ? "control.token" : "access.token")
        let token: String
        if FileManager.default.fileExists(atPath: url.path) {
            token = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard token.count == 64, token.allSatisfy(\.isHexDigit) else { throw NSError(domain: "Credential", code: 1, userInfo: [NSLocalizedDescriptionKey: "访问令牌文件格式错误，请先移走该文件再启动。"] ) }
        } else {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw NSError(domain: "Credential", code: 2) }
            token = bytes.map { String(format: "%02x", $0) }.joined()
            // File stays inaccessible to other accounts even during the atomic write.
            guard FileManager.default.createFile(atPath: url.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else {
                throw NSError(domain: "Credential", code: 3)
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return (token, url.path)
    }
}

// After start(), listener/connection mutation is confined to queue. The HomeKit
// provider and status callback are always invoked on MainActor.
final class HTTPServer: @unchecked Sendable {
    static let port: UInt16 = 18765
    private let queue = DispatchQueue(label: "HomeKitReadOnly.HTTP")
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private let policy: HTTPPolicy
    private let handle: @MainActor (Data, AccessRole) async -> RPCReply
    private let onState: @MainActor (String) -> Void

    init(token: String, controlToken: String, handle: @escaping @MainActor (Data, AccessRole) async -> RPCReply, onState: @escaping @MainActor (String) -> Void) {
        policy = HTTPPolicy(port: Self.port, token: token, controlToken: controlToken)
        self.handle = handle
        self.onState = onState
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor in
                switch state {
                case .ready: self.onState("运行中 · http://127.0.0.1:\(Self.port)/mcp")
                case .failed(let error): self.onState("服务启动失败：\(error.localizedDescription)")
                case .cancelled: self.onState("已停止")
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.connections.values.forEach { $0.cancel() }
            self.connections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 16 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 60) { [weak self] in self?.close(id) }
        receive(id, buffer: Data())
    }

    private func receive(_ id: UUID, buffer: Data) {
        guard let connection = connections[id] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self, self.connections[id] != nil else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            do {
                if let request = try HTTPParser.parse(buffer) {
                    let role = try self.policy.authorize(request)
                    Task { @MainActor in
                        let reply = await self.handle(request.body, role)
                        let body = reply.json.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) } ?? Data()
                        let status = reply.status
                        self.queue.async { self.send(id, status: status, body: body) }
                    }
                } else if complete || error != nil {
                    self.close(id)
                } else {
                    self.receive(id, buffer: buffer)
                }
            } catch HTTPFailure.rejected(let status, let message) {
                let body = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()
                self.send(id, status: status, body: body)
            } catch {
                self.send(id, status: 400, body: Data("{\"error\":\"Bad request\"}".utf8))
            }
        }
    }

    private func send(_ id: UUID, status: Int, body: Data) {
        guard let connection = connections[id] else { return }
        let reasons = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 406: "Not Acceptable", 413: "Content Too Large", 415: "Unsupported Media Type", 431: "Request Header Fields Too Large"]
        var headers = "HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n"
        if status == 401 { headers += "WWW-Authenticate: Bearer\r\n" }
        if status == 405 { headers += "Allow: POST\r\n" }
        var data = Data((headers + "\r\n").utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in self?.close(id) })
    }

    private func close(_ id: UUID) { connections.removeValue(forKey: id)?.cancel() }
}
