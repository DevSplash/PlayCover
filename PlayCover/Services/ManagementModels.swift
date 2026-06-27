//
//  ManagementModels.swift
//  PlayCover
//

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

    var jsonBody: [String: Any] {
        guard !body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: body),
              let dictionary = object as? [String: Any] else {
            return [:]
        }
        return dictionary
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
}
