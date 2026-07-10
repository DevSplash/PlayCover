//
//  PortProbe.swift
//  PlayCover
//

import Darwin
import Foundation

enum PortProbe {
    static func isOpen(host: String, port: Int, timeout: TimeInterval = 0.5) async -> Bool {
        await Task.detached(priority: .utility) {
            guard let socketDescriptor = SocketProbe.connect(host: host, port: port, timeout: timeout) else {
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
    static func inspect(host: String,
                        port: Int,
                        expectedBundleIdentifier: String,
                        timeout: TimeInterval = 0.5) async -> MaaToolsProbeResult? {
        await Task.detached(priority: .utility) {
            inspectSync(host: host,
                        port: port,
                        expectedBundleIdentifier: expectedBundleIdentifier,
                        timeout: timeout)
        }.value
    }

    private static func inspectSync(host: String,
                                    port: Int,
                                    expectedBundleIdentifier: String,
                                    timeout: TimeInterval) -> MaaToolsProbeResult? {
        guard let socketDescriptor = SocketProbe.connect(host: host, port: port, timeout: timeout) else {
            return nil
        }
        defer { Darwin.close(socketDescriptor) }

        let connectionMagic = Data([0x4d, 0x41, 0x41, 0x00])
        guard SocketProbe.sendAll(connectionMagic, to: socketDescriptor),
              SocketProbe.receive(count: 4, from: socketDescriptor) == Data("OKAY".utf8),
              send(command: "VERN", to: socketDescriptor),
              let versionData = SocketProbe.receive(count: 4, from: socketDescriptor) else {
            return nil
        }

        let version = unsignedInteger(from: versionData)
        guard version >= 3,
              send(command: "BNDL", to: socketDescriptor),
              let lengthData = SocketProbe.receive(count: 4, from: socketDescriptor) else {
            return nil
        }

        let bundleLength = unsignedInteger(from: lengthData)
        guard (1 ... 4096).contains(bundleLength),
              let bundleData = SocketProbe.receive(count: bundleLength, from: socketDescriptor),
              let bundleIdentifier = String(data: bundleData, encoding: .utf8),
              bundleIdentifier == expectedBundleIdentifier else {
            return nil
        }

        return MaaToolsProbeResult(version: version, bundleIdentifier: bundleIdentifier)
    }

    private static func send(command: String, to socketDescriptor: Int32) -> Bool {
        let commandData = Data(command.utf8)
        guard commandData.count <= Int(UInt16.max) else { return false }

        var payload = Data([
            UInt8(commandData.count >> 8 & 0xff),
            UInt8(commandData.count & 0xff)
        ])
        payload.append(commandData)
        return SocketProbe.sendAll(payload, to: socketDescriptor)
    }

    private static func unsignedInteger(from data: Data) -> Int {
        data.reduce(0) { ($0 << 8) | Int($1) }
    }
}

private enum SocketProbe {
    static func connect(host: String, port: Int, timeout: TimeInterval) -> Int32? {
        guard (1 ... 65535).contains(port), timeout.isFinite, timeout > 0 else { return nil }

        let socketDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { return nil }
        var keepSocket = false
        defer {
            if !keepSocket {
                Darwin.close(socketDescriptor)
            }
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian

        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return nil }

        let flags = fcntl(socketDescriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(socketDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return nil
        }

        let connectResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if connectResult != 0 {
            guard errno == EINPROGRESS else { return nil }

            var pollFD = pollfd(fd: socketDescriptor, events: Int16(POLLOUT), revents: 0)
            let timeoutMS = max(1, Int32(min(timeout * 1000, Double(Int32.max)).rounded()))
            guard Darwin.poll(&pollFD, 1, timeoutMS) > 0,
                  pollFD.revents & Int16(POLLOUT) != 0 else {
                return nil
            }

            var error: Int32 = 0
            var errorLength = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(socketDescriptor, SOL_SOCKET, SO_ERROR, &error, &errorLength) == 0,
                  error == 0 else {
                return nil
            }
        }

        guard fcntl(socketDescriptor, F_SETFL, flags) == 0 else { return nil }
        configure(socketDescriptor, timeout: timeout)
        keepSocket = true
        return socketDescriptor
    }

    static func sendAll(_ data: Data, to socketDescriptor: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return data.isEmpty }
            var sent = 0
            while sent < data.count {
                let count = Darwin.send(socketDescriptor,
                                        baseAddress.advanced(by: sent),
                                        data.count - sent,
                                        0)
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }

    static func receive(count: Int, from socketDescriptor: Int32) -> Data? {
        guard count >= 0 else { return nil }
        var data = Data(count: count)
        let receivedAll = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress else { return count == 0 }
            var received = 0
            while received < count {
                let result = Darwin.recv(socketDescriptor,
                                         baseAddress.advanced(by: received),
                                         count - received,
                                         0)
                guard result > 0 else { return false }
                received += result
            }
            return true
        }
        return receivedAll ? data : nil
    }

    private static func configure(_ socketDescriptor: Int32, timeout: TimeInterval) {
        var noSigPipe: Int32 = 1
        setsockopt(socketDescriptor,
                   SOL_SOCKET,
                   SO_NOSIGPIPE,
                   &noSigPipe,
                   socklen_t(MemoryLayout<Int32>.size))

        let wholeSeconds = floor(timeout)
        var socketTimeout = timeval(
            tv_sec: Int(wholeSeconds),
            tv_usec: Int32((timeout - wholeSeconds) * 1_000_000)
        )
        setsockopt(socketDescriptor,
                   SOL_SOCKET,
                   SO_RCVTIMEO,
                   &socketTimeout,
                   socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socketDescriptor,
                   SOL_SOCKET,
                   SO_SNDTIMEO,
                   &socketTimeout,
                   socklen_t(MemoryLayout<timeval>.size))
    }
}
