//
//  PortProbe.swift
//  PlayCover
//

import Darwin
import Foundation

enum PortProbe {
    static func isOpen(host: String, port: Int, timeout: TimeInterval = 0.5) async -> Bool {
        await Task.detached(priority: .utility) {
            isOpenSync(host: host, port: port, timeout: timeout)
        }.value
    }

    private static func isOpenSync(host: String, port: Int, timeout: TimeInterval) -> Bool {
        guard (1 ... 65535).contains(port) else { return false }

        let socketDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { return false }
        defer { Darwin.close(socketDescriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian

        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            return false
        }

        let flags = fcntl(socketDescriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(socketDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return false
        }

        let connectResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if connectResult == 0 {
            return true
        }

        guard errno == EINPROGRESS else {
            return false
        }

        var pollFD = pollfd(fd: socketDescriptor, events: Int16(POLLOUT), revents: 0)
        let timeoutMS = max(1, Int32((timeout * 1000).rounded()))
        guard Darwin.poll(&pollFD, 1, timeoutMS) > 0,
              pollFD.revents & Int16(POLLOUT) != 0 else {
            return false
        }

        var error: Int32 = 0
        var errorLength = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(socketDescriptor, SOL_SOCKET, SO_ERROR, &error, &errorLength) == 0 else {
            return false
        }

        return error == 0
    }
}
