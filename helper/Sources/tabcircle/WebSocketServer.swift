import AppKit
import Foundation
import Network

/// Minimalist loopback WebSocket server.
///
/// Uses Network.framework's built-in `NWProtocolWebSocket` for HTTP upgrade handshake
/// and frame framing without blocking system calls.
///
/// Multi-client support: each connection receives a UUID. Browser identity is resolved by
/// tracing remote TCP port -> lsof pid -> parent process chain -> NSRunningApplication bundle ID.
final class WebSocketServer {

    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "com.tabcircle.websocket")
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]

    /// Text frame received. Callback dispatched on main thread with client ID.
    var onText: ((Data, UUID) -> Void)?
    /// New client connected. Callback dispatched on main thread.
    var onClientConnected: ((UUID) -> Void)?
    /// Client disconnected. Callback dispatched on main thread.
    var onClientDisconnected: ((UUID) -> Void)?
    /// Owning browser resolved (bundle ID). Callback dispatched on main thread.
    var onClientIdentified: ((UUID, String) -> Void)?

    init(port: UInt16) {
        guard let p = NWEndpoint.Port(rawValue: port) else {
            fatalError("Invalid port \(port)")
        }
        self.port = p
    }

    // MARK: - Lifecycle

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Bind exclusively to loopback interface
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)

        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true          // Protocol-level ping auto-response
        params.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)

        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                DispatchQueue.main.async {
                    log("❌ WebSocket listener failed: \(error)")
                }
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.queue.async {
                    self.connections[id] = connection
                    DispatchQueue.main.async { self.onClientConnected?(id) }
                }
                self.receive(on: connection, id: id)
                self.resolveBrowser(of: connection, id: id)
            case .failed, .cancelled:
                self.remove(id, connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func remove(_ id: UUID, _ connection: NWConnection) {
        queue.async {
            guard self.connections.removeValue(forKey: id) != nil else { return }
            connection.cancel()
            DispatchQueue.main.async { self.onClientDisconnected?(id) }
        }
    }

    private func receive(on connection: NWConnection, id: UUID) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }

            if let error {
                if case .posix(.ECANCELED) = error {} else {
                    DispatchQueue.main.async { log("WebSocket receive error: \(error)") }
                }
                self.remove(id, connection)
                return
            }

            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata

            if metadata?.opcode == .close {
                self.remove(id, connection)
                return
            }

            if metadata?.opcode == .text, let data, !data.isEmpty {
                DispatchQueue.main.async { self.onText?(data, id) }
            }

            self.receive(on: connection, id: id)   // Continue receiving next message
        }
    }

    // MARK: - Browser Resolution

    private func resolveBrowser(of connection: NWConnection, id: UUID) {
        guard case let .hostPort(_, remotePort) = connection.endpoint else { return }
        let portValue = remotePort.rawValue
        DispatchQueue.global(qos: .utility).async {
            let pids = Self.pidsOnPort(portValue).filter { $0 != getpid() }
            DispatchQueue.main.async {
                for pid in pids {
                    if let bundleID = Self.owningAppBundleID(of: pid) {
                        log("🔎 client \(id.uuidString.prefix(8)) → \(bundleID)")
                        self.onClientIdentified?(id, bundleID)
                        return
                    }
                }
                log("🔎 client \(id.uuidString.prefix(8)) → Browser identity unidentified (single-browser mode unaffected)")
            }
        }
    }

    /// List processes on given TCP port in ESTABLISHED state.
    private static func pidsOnPort(_ port: UInt16) -> [pid_t] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:ESTABLISHED", "-t"]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return [] }
        task.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
    }

    /// Walk up parent process hierarchy to locate the owning application bundle ID.
    private static func owningAppBundleID(of pid: pid_t) -> String? {
        var current = pid
        for _ in 0..<12 {
            if let app = NSRunningApplication(processIdentifier: current),
               let bundleID = app.bundleIdentifier {
                return bundleID
            }
            guard let parent = parentPID(of: current), parent > 1, parent != current else { return nil }
            current = parent
        }
        return nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    // MARK: - Sending

    /// Send to a specific client.
    func send(_ object: [String: Any], to id: UUID) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])

        queue.async {
            guard let connection = self.connections[id] else { return }
            connection.send(content: data,
                            contentContext: context,
                            isComplete: true,
                            completion: .contentProcessed { _ in })
        }
    }

    func broadcast(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])

        queue.async {
            for connection in self.connections.values {
                connection.send(content: data,
                                contentContext: context,
                                isComplete: true,
                                completion: .contentProcessed { _ in })
            }
        }
    }
}
