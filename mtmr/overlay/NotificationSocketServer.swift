import Foundation
import Darwin

final class NotificationSocketServer {
    static let shared = NotificationSocketServer()

    private final class Client {
        let descriptor: Int32
        let source: DispatchSourceRead
        var buffer = Data()
        var pendingCommands = 0
        var timeout: DispatchWorkItem?

        init(descriptor: Int32, queue: DispatchQueue) {
            self.descriptor = descriptor
            source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        }
    }

    private struct Command: Decodable {
        let cmd: String
        let text: String?
        let seconds: Double?
    }

    /// Extra commands registered by features (e.g. App Controls). Runs on the main queue with the whole
    /// command object; returns extra reply fields, or throws LiveButtonError to reject.
    typealias CommandHandler = ([String: Any]) throws -> [String: Any]
    private var handlers: [String: CommandHandler] = [:]

    func register(_ name: String, handler: @escaping CommandHandler) {
        dispatchPrecondition(condition: .onQueue(.main))
        handlers[name] = handler
    }

    private typealias Reply = [String: Any]

    private let queue = DispatchQueue(label: "MTMRNotificationSocket")
    private let socketPath = appSupportDirectory + "/mtmr.sock"
    private var listener: DispatchSourceRead?
    private var clients: [Int32: Client] = [:]
    private var socketInode: ino_t?

    func start() {
        do {
            try FileManager.default.createDirectory(atPath: appSupportDirectory, withIntermediateDirectories: true, attributes: nil)
            var address = try socketAddress()
            try removeStaleSocket(address: &address)
            let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw systemError() }
            var listening = false
            defer { if !listening { Darwin.close(descriptor) } }
            try configure(descriptor: descriptor)
            let previousMask = umask(0o077)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            umask(previousMask)
            guard bound == 0 else { throw systemError() }
            var socketStatus = stat()
            guard lstat(socketPath, &socketStatus) == 0 else { throw systemError() }
            socketInode = socketStatus.st_ino
            guard chmod(socketPath, 0o600) == 0 else { throw systemError() }
            guard Darwin.listen(descriptor, 16) == 0 else { throw systemError() }
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptClients(descriptor: descriptor) }
            source.setCancelHandler { Darwin.close(descriptor) }
            listener = source
            listening = true
            source.resume()
        } catch {
            NSLog("MTMR notification socket start failed: %@", String(describing: error))
            removeOwnedSocket()
        }
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for client in Array(clients.values) {
                disconnect(client)
            }
            removeOwnedSocket()
        }
    }

    private func socketAddress() throws -> sockaddr_un {
        var address = sockaddr_un()
        let pathBytes = Array(socketPath.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw NSError(domain: "MTMRNotificationSocket", code: 1, userInfo: [NSLocalizedDescriptionKey: "Socket path is too long"])
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: pathBytes)
        }
        return address
    }

    private func removeStaleSocket(address: inout sockaddr_un) throws {
        var socketStatus = stat()
        if lstat(socketPath, &socketStatus) != 0 {
            guard errno == ENOENT else { throw systemError() }
            return
        }
        guard socketStatus.st_uid == getuid() else {
            throw NSError(domain: "MTMRNotificationSocket", code: 2, userInfo: [NSLocalizedDescriptionKey: "Socket path is owned by another user"])
        }
        guard socketStatus.st_mode & S_IFMT == S_IFSOCK else {
            throw NSError(domain: "MTMRNotificationSocket", code: 3, userInfo: [NSLocalizedDescriptionKey: "Refusing to remove a non-socket path"])
        }
        let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw systemError() }
        defer { Darwin.close(probe) }
        try configure(descriptor: probe)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected != 0 else {
            throw NSError(domain: "MTMRNotificationSocket", code: 4, userInfo: [NSLocalizedDescriptionKey: "Another MTMR instance owns the socket"])
        }
        guard errno == ECONNREFUSED else { throw systemError() }
        guard unlink(socketPath) == 0 else { throw systemError() }
    }

    private func removeOwnedSocket() {
        guard let socketInode = socketInode else { return }
        var socketStatus = stat()
        if lstat(socketPath, &socketStatus) == 0 {
            if socketStatus.st_ino == socketInode {
                if unlink(socketPath) != 0 {
                    NSLog("MTMR socket cleanup failed: %@", String(describing: systemError()))
                }
            }
        } else if errno != ENOENT {
            NSLog("MTMR socket cleanup stat failed: %@", String(describing: systemError()))
        }
        self.socketInode = nil
    }

    private func configure(descriptor: Int32) throws {
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw systemError() }
        var enabled: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw systemError()
        }
    }

    private func acceptClients(descriptor: Int32) {
        while true {
            let accepted = Darwin.accept(descriptor, nil, nil)
            if accepted < 0 {
                if errno == EAGAIN { return }
                if errno == EINTR { continue }
                NSLog("MTMR socket accept failed: %@", String(describing: systemError()))
                return
            }
            guard clients.count < 16 else {
                NSLog("MTMR socket client limit reached")
                Darwin.close(accepted)
                continue
            }
            do {
                try configure(descriptor: accepted)
            } catch {
                NSLog("MTMR socket client setup failed: %@", String(describing: error))
                Darwin.close(accepted)
                continue
            }
            let client = Client(descriptor: accepted, queue: queue)
            clients[accepted] = client
            client.source.setEventHandler { [weak self, weak client] in
                if let client = client { self?.receive(client) }
            }
            client.source.setCancelHandler { Darwin.close(accepted) }
            client.source.resume()
            resetTimeout(client)
        }
    }

    private func receive(_ client: Client) {
        var bytes = [UInt8](repeating: 0, count: 1024)
        let received = Darwin.recv(client.descriptor, &bytes, bytes.count, 0)
        if received <= 0 {
            if received < 0 {
                if errno == EAGAIN { return }
                if errno == EINTR { return }
                NSLog("MTMR socket receive failed: %@", String(describing: systemError()))
            }
            disconnect(client)
            return
        }
        resetTimeout(client)
        for byte in bytes.prefix(received) {
            if byte == 10 {
                guard client.pendingCommands < 16 else {
                    send(rejected("Too many pending commands"), to: client)
                    disconnect(client)
                    return
                }
                client.pendingCommands += 1
                let line = client.buffer
                client.buffer.removeAll(keepingCapacity: true)
                DispatchQueue.main.async { [weak self, weak client] in
                    guard let self = self, let client = client else { return }
                    let reply = self.process(line)
                    self.queue.async {
                        guard self.clients[client.descriptor] === client else { return }
                        client.pendingCommands -= 1
                        self.send(reply, to: client)
                    }
                }
            } else {
                guard client.buffer.count < 4096 else {
                    send(rejected("Line exceeds 4096 bytes"), to: client)
                    disconnect(client)
                    return
                }
                client.buffer.append(byte)
            }
        }
    }

    private func process(_ line: Data) -> Reply {
        dispatchPrecondition(condition: .onQueue(.main))
        do {
            let command = try JSONDecoder().decode(Command.self, from: line)
            switch command.cmd {
            case "notify":
                guard let text = command.text else { return rejected("notify requires text") }
                if let seconds = command.seconds {
                    guard seconds.isFinite else { return rejected("seconds must be finite") }
                    guard seconds > 0 else { return rejected("seconds must be positive") }
                    guard seconds <= 86400 else { return rejected("seconds must not exceed 86400") }
                }
                guard NotificationStore.shared.notify(text: text, seconds: command.seconds) else {
                    return rejected("Notification queue is full (256 entries)")
                }
            case "clear":
                NotificationStore.shared.clear()
            case "button":
                guard let fields = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    return rejected("Invalid JSON command")
                }
                do {
                    try LiveButtonStore.shared.update(fields)
                } catch {
                    return rejected(error.localizedDescription)
                }
            case "buttons":
                return ["ok": true, "buttons": LiveButtonStore.shared.buttons()]
            default:
                guard let handler = handlers[command.cmd] else { return rejected("Unknown command: \(command.cmd)") }
                guard let fields = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    return rejected("Invalid JSON command")
                }
                do {
                    return try handler(fields).merging(["ok": true]) { _, ok in ok }
                } catch {
                    return rejected(error.localizedDescription)
                }
            }
            return ["ok": true]
        } catch {
            NSLog("MTMR socket invalid JSON: %@", String(describing: error))
            return ["ok": false, "error": "Invalid JSON command"]
        }
    }

    private func rejected(_ message: String) -> Reply {
        NSLog("MTMR socket command rejected: %@", message)
        return ["ok": false, "error": message]
    }

    private func send(_ reply: Reply, to client: Client) {
        do {
            var replyBytes = try JSONSerialization.data(withJSONObject: reply)
            replyBytes.append(10)
            var sent = 0
            while sent < replyBytes.count {
                let count = replyBytes.withUnsafeBytes {
                    Darwin.send(client.descriptor, $0.baseAddress!.advanced(by: sent), replyBytes.count - sent, 0)
                }
                if count <= 0 {
                    if errno == EINTR { continue }
                    NSLog("MTMR socket send failed: %@", String(describing: systemError()))
                    disconnect(client)
                    return
                }
                sent += count
            }
        } catch {
            NSLog("MTMR socket reply encoding failed: %@", String(describing: error))
            disconnect(client)
        }
    }

    private func resetTimeout(_ client: Client) {
        client.timeout?.cancel()
        let timeout = DispatchWorkItem { [weak self, weak client] in
            if let client = client { self?.disconnect(client) }
        }
        client.timeout = timeout
        queue.asyncAfter(deadline: .now() + 5, execute: timeout)
    }

    private func disconnect(_ client: Client) {
        guard clients[client.descriptor] === client else { return }
        clients.removeValue(forKey: client.descriptor)
        client.timeout?.cancel()
        client.source.cancel()
    }

    private func systemError() -> NSError {
        return NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
    }
}
