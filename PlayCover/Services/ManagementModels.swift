//
//  ManagementModels.swift
//  PlayCover
//

import Darwin
import Foundation

struct ManagementRequest {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data

    var components: URLComponents? {
        URLComponents(string: "http://localhost\(target)")
    }

    var pathSegments: [String] {
        guard let path = components?.percentEncodedPath else { return [] }
        return path
            .split(separator: "/")
            .map { String($0).removingPercentEncoding ?? String($0) }
    }

    var queryItems: [String: String] {
        var result: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            result[item.name] = item.value ?? ""
        }
        return result
    }

    var jsonBody: ManagementBody {
        guard !body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: body),
              let dictionary = object as? [String: Any] else {
            return ManagementBody()
        }
        return ManagementBody(dictionary)
    }
}

struct ManagementBody {
    private let values: [String: Any]

    init(_ values: [String: Any] = [:]) {
        self.values = values
    }

    subscript(key: String) -> Any? {
        values[key]
    }

    func boolValue(_ key: String, defaultValue: Bool) -> Bool {
        values[key] as? Bool ?? defaultValue
    }

    func timeoutValue(_ key: String, defaultValue: TimeInterval) -> TimeInterval? {
        let value: Double
        if let rawValue = values[key] {
            guard !(rawValue is Bool) else { return nil }
            if let doubleValue = rawValue as? Double {
                value = doubleValue
            } else if let intValue = rawValue as? Int {
                value = Double(intValue)
            } else {
                return nil
            }
        } else {
            value = defaultValue
        }

        guard value.isFinite, (0.1 ... 120).contains(value) else { return nil }
        return value
    }

    func intValue(_ key: String) -> Int? {
        guard !(values[key] is Bool) else { return nil }
        if let value = values[key] as? Int {
            return value
        }
        if let value = values[key] as? Double,
           value.isFinite,
           value.rounded() == value,
           (Double(Int32.min) ... Double(Int32.max)).contains(value) {
            return Int(value)
        }
        return nil
    }
}

struct ManagementResponse {
    let statusCode: Int
    let payload: Any

    var reason: String {
        switch statusCode {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return "Internal Server Error"
        }
    }

    var bodyData: Data {
        (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])) ?? Data("{}".utf8)
    }

    static func ok(_ payload: Any) -> ManagementResponse {
        ManagementResponse(statusCode: 200, payload: payload)
    }

    static func badRequest(_ payload: Any) -> ManagementResponse {
        ManagementResponse(statusCode: 400, payload: payload)
    }

    static func unauthorized(_ payload: Any) -> ManagementResponse {
        ManagementResponse(statusCode: 401, payload: payload)
    }

    static func notFound(_ payload: Any) -> ManagementResponse {
        ManagementResponse(statusCode: 404, payload: payload)
    }

    static func conflict(_ payload: Any) -> ManagementResponse {
        ManagementResponse(statusCode: 409, payload: payload)
    }

    static func serviceUnavailable(_ payload: Any) -> ManagementResponse {
        ManagementResponse(statusCode: 503, payload: payload)
    }

    static func gatewayTimeout(_ payload: Any) -> ManagementResponse {
        ManagementResponse(statusCode: 504, payload: payload)
    }
}

struct MaaToolsSettingsSnapshot {
    let enabled: Bool
    let port: Int
}

struct AppSnapshot {
    let bundleIdentifier: String
    let name: String
    let path: String
    let running: Bool
    let pid: pid_t?
    let maaToolsEnabled: Bool
    let maaToolsPort: Int

    func dictionary(maaToolsReachable: Bool) -> [String: Any] {
        let processIdentifier: Any
        if let pid = pid {
            processIdentifier = Int(pid)
        } else {
            processIdentifier = NSNull()
        }

        return [
            "bundleIdentifier": bundleIdentifier,
            "name": name,
            "path": path,
            "running": running,
            "pid": processIdentifier,
            "maaTools": [
                "enabled": maaToolsEnabled,
                "port": maaToolsPort,
                "reachable": maaToolsReachable
            ]
        ]
    }
}
