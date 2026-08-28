//
//  PortProbe.swift
//  PlayCover
//

import Darwin
import Foundation

enum PortProbe {
    static func isOpen(host: String, port: Int, timeout: TimeInterval = 0.5) async -> Bool {
        guard let deadline = SocketProbeDeadline(timeout: timeout) else { return false }
        return await Task.detached(priority: .utility) {
            guard let socketDescriptor = SocketProbe.connect(host: host, port: port, deadline: deadline) else {
                return false
            }
            Darwin.close(socketDescriptor)
            return true
        }.value
    }
}

struct MaaToolsProbeResult: Sendable {
    let version: Int
    let bundleIdentifier: String
}

enum MaaToolsProbe {
    static let defaultTimeout: TimeInterval = 2

    static func inspect(host: String,
                        port: Int,
                        timeout: TimeInterval = MaaToolsProbe.defaultTimeout,
                        within budget: SocketProbeDeadline? = nil) async -> MaaToolsProbeResult? {
        // Start the shared budget before scheduling the worker, not once per socket operation.
        guard let deadline = SocketProbeDeadline(timeout: timeout, boundedBy: budget),
              !deadline.isExpired else { return nil }
        return await Task.detached(priority: .utility) {
            inspectSync(host: host, port: port, deadline: deadline)
        }.value
    }

    static func inspect(host: String,
                        port: Int,
                        expectedBundleIdentifier: String,
                        timeout: TimeInterval = MaaToolsProbe.defaultTimeout,
                        within budget: SocketProbeDeadline? = nil) async -> MaaToolsProbeResult? {
        guard let result = await inspect(host: host, port: port, timeout: timeout, within: budget),
              result.bundleIdentifier == expectedBundleIdentifier else {
            return nil
        }
        return result
    }

    private static func inspectSync(host: String,
                                    port: Int,
                                    deadline: SocketProbeDeadline) -> MaaToolsProbeResult? {
        guard let socketDescriptor = SocketProbe.connect(host: host, port: port, deadline: deadline) else {
            return nil
        }
        defer { Darwin.close(socketDescriptor) }

        let connectionMagic = Data([0x4d, 0x41, 0x41, 0x00])
        guard SocketProbe.sendAll(connectionMagic, to: socketDescriptor, deadline: deadline),
              SocketProbe.receive(count: 4, from: socketDescriptor, deadline: deadline) == Data("OKAY".utf8),
              send(command: "VERN", to: socketDescriptor, deadline: deadline),
              let versionData = SocketProbe.receive(count: 4, from: socketDescriptor, deadline: deadline) else {
            return nil
        }

        let version = unsignedInteger(from: versionData)
        guard version >= 3,
              send(command: "BNDL", to: socketDescriptor, deadline: deadline),
              let lengthData = SocketProbe.receive(count: 4, from: socketDescriptor, deadline: deadline) else {
            return nil
        }

        let bundleLength = unsignedInteger(from: lengthData)
        guard (1 ... 4096).contains(bundleLength),
              let bundleData = SocketProbe.receive(count: bundleLength, from: socketDescriptor, deadline: deadline),
              let bundleIdentifier = String(data: bundleData, encoding: .utf8),
              !bundleIdentifier.isEmpty, !deadline.isExpired else {
            return nil
        }

        return MaaToolsProbeResult(version: version, bundleIdentifier: bundleIdentifier)
    }

    private static func send(command: String, to socketDescriptor: Int32, deadline: SocketProbeDeadline) -> Bool {
        let commandData = Data(command.utf8)
        guard commandData.count <= Int(UInt16.max) else { return false }

        var payload = Data([
            UInt8(commandData.count >> 8 & 0xff),
            UInt8(commandData.count & 0xff)
        ])
        payload.append(commandData)
        return SocketProbe.sendAll(payload, to: socketDescriptor, deadline: deadline)
    }

    private static func unsignedInteger(from data: Data) -> Int {
        data.reduce(0) { ($0 << 8) | Int($1) }
    }
}

struct SocketProbeDeadline: Sendable {
    private let expiresAt: TimeInterval

    init?(timeout: TimeInterval, boundedBy budget: SocketProbeDeadline? = nil) {
        guard timeout.isFinite, timeout > 0 else { return nil }
        let expiresAt = ProcessInfo.processInfo.systemUptime + timeout
        guard expiresAt.isFinite else { return nil }
        if let budget {
            self.expiresAt = min(expiresAt, budget.expiresAt)
        } else {
            self.expiresAt = expiresAt
        }
    }

    var remainingTime: TimeInterval {
        max(0, expiresAt - ProcessInfo.processInfo.systemUptime)
    }

    var isExpired: Bool {
        ProcessInfo.processInfo.systemUptime >= expiresAt
    }

    var pollTimeoutMilliseconds: Int32? {
        let remaining = remainingTime
        guard remaining > 0 else { return nil }
        // poll uses whole milliseconds; recheck the deadline after it wakes.
        return Int32(min(remaining * 1_000, Double(Int32.max)).rounded(.up))
    }
}

private enum SocketProbe {
    static func connect(host: String, port: Int, deadline: SocketProbeDeadline) -> Int32? {
        guard (1 ... 65535).contains(port), !deadline.isExpired else { return nil }

        let socketDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { return nil }
        var keepSocket = false
        defer {
            if !keepSocket {
                Darwin.close(socketDescriptor)
            }
        }
        guard configure(socketDescriptor) else { return nil }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian

        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return nil }

        let connectResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if connectResult != 0 {
            guard errno == EINPROGRESS || errno == EINTR else { return nil }
            guard waitUntilReady(socketDescriptor, events: Int16(POLLOUT), deadline: deadline) else {
                return nil
            }

            var error: Int32 = 0
            var errorLength = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(socketDescriptor, SOL_SOCKET, SO_ERROR, &error, &errorLength) == 0,
                  error == 0 else {
                return nil
            }
        }

        guard !deadline.isExpired else { return nil }
        keepSocket = true
        return socketDescriptor
    }

    static func sendAll(_ data: Data, to socketDescriptor: Int32, deadline: SocketProbeDeadline) -> Bool {
        guard !deadline.isExpired else { return false }
        return data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return data.isEmpty }
            var sent = 0
            while sent < data.count {
                guard waitUntilReady(socketDescriptor, events: Int16(POLLOUT), deadline: deadline) else {
                    return false
                }
                let count = Darwin.send(socketDescriptor,
                                        baseAddress.advanced(by: sent),
                                        data.count - sent,
                                        0)
                if count < 0 && shouldRetryIO() { continue }
                guard count > 0 else { return false }
                sent += count
            }
            return !deadline.isExpired
        }
    }

    static func receive(count: Int, from socketDescriptor: Int32, deadline: SocketProbeDeadline) -> Data? {
        guard count >= 0, !deadline.isExpired else { return nil }
        var data = Data(count: count)
        let receivedAll = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress else { return count == 0 }
            var received = 0
            while received < count {
                guard waitUntilReady(socketDescriptor, events: Int16(POLLIN), deadline: deadline) else {
                    return false
                }
                let result = Darwin.recv(socketDescriptor,
                                         baseAddress.advanced(by: received),
                                         count - received,
                                         0)
                if result < 0 && shouldRetryIO() { continue }
                guard result > 0 else { return false }
                received += result
            }
            return !deadline.isExpired
        }
        return receivedAll ? data : nil
    }

    private static func waitUntilReady(_ socketDescriptor: Int32,
                                       events: Int16,
                                       deadline: SocketProbeDeadline) -> Bool {
        var descriptor = pollfd(fd: socketDescriptor, events: events, revents: 0)
        while let timeout = deadline.pollTimeoutMilliseconds {
            let result = Darwin.poll(&descriptor, 1, timeout)
            if result < 0 && errno == EINTR { continue }
            if result == 0 { continue }
            guard result > 0, !deadline.isExpired,
                  descriptor.revents & Int16(POLLNVAL) == 0 else { return false }

            // Let recv drain buffered data on EOF; send/recv/SO_ERROR handle terminal errors.
            let readyEvents = events | Int16(POLLERR) | Int16(POLLHUP)
            return descriptor.revents & readyEvents != 0
        }
        return false
    }

    private static func shouldRetryIO() -> Bool {
        errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK
    }

    private static func configure(_ socketDescriptor: Int32) -> Bool {
        // Keep the socket nonblocking so every retry stays within the shared deadline.
        let flags = fcntl(socketDescriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(socketDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
        var noSigPipe: Int32 = 1
        return setsockopt(socketDescriptor,
                          SOL_SOCKET,
                          SO_NOSIGPIPE,
                          &noSigPipe,
                          socklen_t(MemoryLayout<Int32>.size)) == 0
    }
}
