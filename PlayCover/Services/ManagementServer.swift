//
//  ManagementServer.swift
//  PlayCover
//

import Darwin
import Foundation

enum ManagementServerApplyError: Error {
    case socketCreationFailed
    case portOutOfRange
    case invalidHost
    case portInUse
    case bindFailed
    case listenFailed
}

enum ManagementServerApplyResult {
    case applied
    case stopped
    case failed(ManagementServerApplyError)
}

struct ManagementEndpointSnapshot {
    let socketDescriptor: Int32
    let host: String
    let port: Int

    var isListening: Bool {
        socketDescriptor >= 0
    }
}

final class ManagementServer {
    static let shared = ManagementServer()

    private let queue = DispatchQueue(label: "io.playcover.management.server", qos: .utility)
    private let stateLock = NSLock()
    private var socketFD: Int32 = -1
    private var currentHost = ""
    private var currentPort = 0

    private init() {}

    func applySettings(completion: ((ManagementServerApplyResult) -> Void)? = nil) {
        if ManagementPreferences.shared.enabled {
            start(
                host: ManagementPreferences.shared.host,
                port: ManagementPreferences.shared.port,
                completion: completion
            )
        } else {
            stop(completion: completion)
        }
    }

    func start(host: String, port: Int, completion: ((ManagementServerApplyResult) -> Void)? = nil) {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let listenHost = normalizedHost.isEmpty ? ManagementPreferences.defaultHost : normalizedHost

        queue.async {
            if self.isListening(host: listenHost, port: port) {
                self.complete(.applied, completion: completion)
                return
            }

            guard (1 ... 65535).contains(port) else {
                Log.shared.log("Management server port is out of range: \(port)", isError: true)
                self.complete(.failed(.portOutOfRange), completion: completion)
                return
            }

            switch self.makeListeningSocket(host: listenHost, port: port) {
            case .success(let socketDescriptor):
                self.activate(socketDescriptor, host: listenHost, port: port)
                self.complete(.applied, completion: completion)
            case .failure(let error):
                self.complete(.failed(error), completion: completion)
                return
            }
        }
    }

    func stop(completion: ((ManagementServerApplyResult) -> Void)? = nil) {
        queue.async {
            self.closeSocket()
            self.complete(.stopped, completion: completion)
        }
    }

    private func isListening(host: String, port: Int) -> Bool {
        let currentEndpoint = endpointSnapshot()
        return currentEndpoint.isListening &&
            currentEndpoint.host == host &&
            currentEndpoint.port == port
    }

    private func makeListeningSocket(host: String, port: Int) -> Result<Int32, ManagementServerApplyError> {
        let socketDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else {
            Log.shared.log("Management server failed to create socket: \(String(cString: strerror(errno)))",
                           isError: true)
            return .failure(.socketCreationFailed)
        }

        var reuse: Int32 = 1
        setsockopt(socketDescriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        guard var address = makeAddress(host: host, port: port) else {
            Darwin.close(socketDescriptor)
            Log.shared.log("Management server listen host is not a valid IPv4 address: \(host)", isError: true)
            return .failure(.invalidHost)
        }

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            return bindFailure(for: socketDescriptor, host: host, port: port)
        }

        guard Darwin.listen(socketDescriptor, SOMAXCONN) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(socketDescriptor)
            Log.shared.log("Management server failed to listen on \(host):\(port): \(message)", isError: true)
            return .failure(.listenFailed)
        }

        return .success(socketDescriptor)
    }

    private func complete(_ result: ManagementServerApplyResult,
                          completion: ((ManagementServerApplyResult) -> Void)?) {
        guard let completion = completion else { return }

        DispatchQueue.main.async {
            completion(result)
        }
    }

    private func makeAddress(host: String, port: Int) -> sockaddr_in? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian

        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            return nil
        }

        return address
    }

    private func bindFailure(for socketDescriptor: Int32,
                             host: String,
                             port: Int) -> Result<Int32, ManagementServerApplyError> {
        let bindError = errno
        let message = String(cString: strerror(errno))
        Darwin.close(socketDescriptor)
        Log.shared.log("Management server failed to bind \(host):\(port): \(message)", isError: true)
        return .failure(bindError == EADDRINUSE ? .portInUse : .bindFailed)
    }

    private func activate(_ socketDescriptor: Int32, host: String, port: Int) {
        let oldSocketDescriptor = setSocket(socketDescriptor, host: host, port: port)
        closeSocket(oldSocketDescriptor)
        Log.shared.log("Management server listening on \(host):\(port)")
        DispatchQueue.global(qos: .utility).async {
            self.acceptLoop(socketDescriptor)
        }
    }

    private func setSocket(_ socketDescriptor: Int32, host: String, port: Int) -> Int32 {
        stateLock.lock()
        let oldSocketDescriptor = socketFD
        socketFD = socketDescriptor
        currentHost = host
        currentPort = port
        stateLock.unlock()
        return oldSocketDescriptor
    }

    private func closeSocket() {
        stateLock.lock()
        let socketDescriptor = socketFD
        socketFD = -1
        currentHost = ""
        currentPort = 0
        stateLock.unlock()

        closeSocket(socketDescriptor)
    }

    private func closeSocket(_ socketDescriptor: Int32) {
        guard socketDescriptor >= 0 else { return }
        Darwin.shutdown(socketDescriptor, SHUT_RDWR)
        Darwin.close(socketDescriptor)
    }

    func endpointSnapshot() -> ManagementEndpointSnapshot {
        stateLock.lock()
        let snapshot = ManagementEndpointSnapshot(
            socketDescriptor: socketFD,
            host: currentHost,
            port: currentPort
        )
        stateLock.unlock()
        return snapshot
    }

    private func isActive(socketDescriptor: Int32) -> Bool {
        stateLock.lock()
        let active = socketFD == socketDescriptor
        stateLock.unlock()
        return active
    }

    private func acceptLoop(_ socketDescriptor: Int32) {
        while isActive(socketDescriptor: socketDescriptor) {
            var clientAddress = sockaddr()
            var addressLength = socklen_t(MemoryLayout<sockaddr>.size)
            let clientSocketDescriptor = Darwin.accept(socketDescriptor, &clientAddress, &addressLength)

            if clientSocketDescriptor < 0 {
                if isActive(socketDescriptor: socketDescriptor) {
                    Log.shared.log("Management server accept failed: \(String(cString: strerror(errno)))",
                                   isError: true)
                }
                continue
            }

            configureClientSocket(clientSocketDescriptor)

            Task.detached(priority: .utility) {
                await self.handleConnection(clientSocketDescriptor)
            }
        }
    }

    private func configureClientSocket(_ socketDescriptor: Int32) {
        var noSigPipe: Int32 = 1
        setsockopt(socketDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(socketDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socketDescriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private func handleConnection(_ clientSocketDescriptor: Int32) async {
        defer { Darwin.close(clientSocketDescriptor) }

        guard let request = readRequest(clientSocketDescriptor) else {
            writeResponse(.badRequest(["error": "bad_request"]), to: clientSocketDescriptor)
            return
        }

        guard isAuthorized(request) else {
            writeResponse(.unauthorized(["error": "unauthorized"]), to: clientSocketDescriptor)
            return
        }

        let response = await route(request)
        writeResponse(response, to: clientSocketDescriptor)
    }
}

private extension ManagementServer {
    func readRequest(_ clientSocketDescriptor: Int32) -> ManagementRequest? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let maxRequestSize = 1024 * 1024

        while data.count < maxRequestSize {
            let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else { return -1 }
                return Darwin.recv(clientSocketDescriptor, baseAddress, bytes.count, 0)
            }
            if count <= 0 {
                return nil
            }

            data.append(contentsOf: buffer.prefix(count))

            guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
                continue
            }

            let headerEnd = headerRange.upperBound
            let headerData = data[..<headerRange.lowerBound]
            guard let headerString = String(data: headerData, encoding: .utf8) else {
                return nil
            }

            let lines = headerString.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else { return nil }
            let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
            guard requestParts.count >= 2 else { return nil }

            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
            }

            let contentLength = Int(headers["content-length"] ?? "") ?? 0
            let requiredSize = headerEnd + contentLength
            if data.count < requiredSize {
                continue
            }

            let body = contentLength > 0 ? data[headerEnd..<requiredSize] : Data()
            return ManagementRequest(
                method: requestParts[0].uppercased(),
                target: requestParts[1],
                headers: headers,
                body: Data(body)
            )
        }

        return nil
    }

    func writeResponse(_ response: ManagementResponse, to clientSocketDescriptor: Int32) {
        let body = response.bodyData
        let reason = response.reason
        let header = "HTTP/1.1 \(response.statusCode) \(reason)\r\n" +
            "Content-Type: application/json; charset=utf-8\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "Connection: close\r\n" +
            "\r\n"

        var responseData = Data(header.utf8)
        responseData.append(body)
        sendAll(responseData, to: clientSocketDescriptor)
    }

    func sendAll(_ data: Data, to clientSocketDescriptor: Int32) {
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var sent = 0

            while sent < data.count {
                let pointer = baseAddress.advanced(by: sent)
                let count = Darwin.send(clientSocketDescriptor, pointer, data.count - sent, 0)
                if count <= 0 {
                    return
                }
                sent += count
            }
        }
    }

    func isAuthorized(_ request: ManagementRequest) -> Bool {
        let key = ManagementPreferences.shared.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return true }

        if request.queryItems["key"] == key {
            return true
        }

        if request.headers["x-playcover-key"] == key {
            return true
        }

        if let authorization = request.headers["authorization"],
           authorization == "Bearer \(key)" {
            return true
        }

        return false
    }

}
