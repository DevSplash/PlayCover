//
//  ManagementServer+Routing.swift
//  PlayCover
//

import AppKit
import Foundation

extension ManagementServer {
    func route(_ request: ManagementRequest) async -> ManagementResponse {
        switch request.pathSegments.first {
        case nil:
            return routeRoot(request)
        case "health":
            return routeHealth(request)
        case "apps":
            return await routeApps(request)
        default:
            return .notFound(["error": "not_found"])
        }
    }

    private func routeRoot(_ request: ManagementRequest) -> ManagementResponse {
        guard request.method == "GET", request.pathSegments.isEmpty else {
            return .notFound(["error": "not_found"])
        }

        return .ok([
            "service": "PlayCover Management",
            "endpoints": [
                "GET /health",
                "GET /apps",
                "GET /apps/{bundleIdentifier}",
                "POST /apps/{bundleIdentifier}/start",
                "POST /apps/{bundleIdentifier}/stop",
                "POST /apps/{bundleIdentifier}/restart",
                "POST /apps/{bundleIdentifier}/maatools/open"
            ]
        ])
    }

    private func routeHealth(_ request: ManagementRequest) -> ManagementResponse {
        guard request.method == "GET", request.pathSegments == ["health"] else {
            return .notFound(["error": "not_found"])
        }

        let endpoint = endpointSnapshot()
        return .ok([
            "ok": true,
            "host": endpoint.host,
            "port": endpoint.port
        ])
    }

    private func routeApps(_ request: ManagementRequest) async -> ManagementResponse {
        let segments = request.pathSegments

        switch (request.method, segments.count) {
        case ("GET", 1):
            return await appsResponse()
        case ("GET", 2):
            return await appResponse(bundleIdentifier: segments[1])
        case ("POST", 3) where segments[2] == "start":
            return await startApp(bundleIdentifier: segments[1], body: request.jsonBody)
        case ("POST", 3) where segments[2] == "stop":
            return await stopApp(bundleIdentifier: segments[1], body: request.jsonBody)
        case ("POST", 3) where segments[2] == "restart":
            return await restartApp(bundleIdentifier: segments[1], body: request.jsonBody)
        case ("POST", 4) where segments[2] == "maatools" && segments[3] == "open":
            return await openMaaTools(bundleIdentifier: segments[1], body: request.jsonBody)
        default:
            return .notFound(["error": "not_found"])
        }
    }

    private func appsResponse() async -> ManagementResponse {
        let apps = await installedApps()
        var statuses: [[String: Any]] = []
        for app in apps {
            statuses.append(await status(for: app))
        }
        statuses.sort {
            ($0["bundleIdentifier"] as? String ?? "") < ($1["bundleIdentifier"] as? String ?? "")
        }
        return .ok(["apps": statuses])
    }

    private func appResponse(bundleIdentifier: String) async -> ManagementResponse {
        guard let app = await installedApp(bundleIdentifier: bundleIdentifier) else {
            return .notFound(["error": "app_not_found"])
        }
        return .ok(await status(for: app))
    }

    private func restartApp(bundleIdentifier: String, body: [String: Any]) async -> ManagementResponse {
        let stopResponse = await stopApp(bundleIdentifier: bundleIdentifier, body: body)
        guard stopResponse.statusCode == 200 else { return stopResponse }
        return await startApp(bundleIdentifier: bundleIdentifier, body: body)
    }
}

extension ManagementServer {
    private func installedApps() async -> [PlayApp] {
        await MainActor.run {
            if AppsVM.shared.apps.isEmpty {
                return scanInstalledApps()
            }
            return AppsVM.shared.apps
        }
    }

    private func installedApp(bundleIdentifier: String) async -> PlayApp? {
        await MainActor.run {
            if let app = AppsVM.shared.apps.first(where: { $0.info.bundleIdentifier == bundleIdentifier }) {
                return app
            }
            return scanInstalledApps().first(where: { $0.info.bundleIdentifier == bundleIdentifier })
        }
    }

    @MainActor
    private func scanInstalledApps() -> [PlayApp] {
        do {
            return try FileManager.default
                .contentsOfDirectory(at: AppsVM.appDirectory, includingPropertiesForKeys: nil, options: [])
                .filter { $0.hasDirectoryPath }
                .filter {
                    $0.pathExtension.contains("app") &&
                    FileManager.default.fileExists(
                        atPath: $0.appendingPathComponent("Info")
                            .appendingPathExtension("plist")
                            .path
                    )
                }
                .map { PlayApp(appUrl: $0) }
        } catch {
            Log.shared.log("Management server failed to scan apps: \(error.localizedDescription)", isError: true)
            return []
        }
    }

    private func status(for app: PlayApp) async -> [String: Any] {
        let snapshot = await MainActor.run {
            let runningApp = self.runningApplication(bundleIdentifier: app.info.bundleIdentifier)
            return AppSnapshot(
                bundleIdentifier: app.info.bundleIdentifier,
                name: app.name,
                path: app.url.path,
                running: runningApp != nil,
                pid: runningApp?.processIdentifier,
                maaToolsEnabled: app.settings.settings.maaTools,
                maaToolsPort: app.settings.settings.maaToolsPort
            )
        }

        let reachable = snapshot.maaToolsEnabled
            ? await PortProbe.isOpen(host: "127.0.0.1", port: snapshot.maaToolsPort)
            : false

        return snapshot.dictionary(maaToolsReachable: reachable)
    }

    @MainActor
    private func runningApplication(bundleIdentifier: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated })
    }

    private func startApp(bundleIdentifier: String, body: [String: Any]) async -> ManagementResponse {
        guard let app = await installedApp(bundleIdentifier: bundleIdentifier) else {
            return .notFound(["error": "app_not_found"])
        }

        if await MainActor.run(body: { runningApplication(bundleIdentifier: bundleIdentifier) != nil }) {
            return .ok(await status(for: app))
        }

        await app.launch()
        let timeout = body.doubleValue("timeout", defaultValue: 15)
        _ = await waitForRunning(bundleIdentifier: bundleIdentifier, timeout: timeout)
        return .ok(await status(for: app))
    }

    private func stopApp(bundleIdentifier: String, body: [String: Any]) async -> ManagementResponse {
        guard let app = await installedApp(bundleIdentifier: bundleIdentifier) else {
            return .notFound(["error": "app_not_found"])
        }

        guard let runningApp = await MainActor.run(body: {
            runningApplication(bundleIdentifier: bundleIdentifier)
        }) else {
            return .ok(await status(for: app))
        }

        let force = body.boolValue("force", defaultValue: false)
        let timeout = body.doubleValue("timeout", defaultValue: 10)

        _ = await MainActor.run {
            if force {
                runningApp.forceTerminate()
            } else {
                runningApp.terminate()
            }
        }

        if !force {
            let stopped = await waitForStopped(bundleIdentifier: bundleIdentifier, timeout: timeout)
            if !stopped {
                _ = await MainActor.run {
                    runningApp.forceTerminate()
                }
                _ = await waitForStopped(bundleIdentifier: bundleIdentifier, timeout: 5)
            }
        } else {
            _ = await waitForStopped(bundleIdentifier: bundleIdentifier, timeout: timeout)
        }

        return .ok(await status(for: app))
    }

    private func openMaaTools(bundleIdentifier: String, body: [String: Any]) async -> ManagementResponse {
        guard let app = await installedApp(bundleIdentifier: bundleIdentifier) else {
            return .notFound(["error": "app_not_found"])
        }

        let requestedPort = body.intValue("port")
        if let requestedPort = requestedPort, !(1024 ... 65535).contains(requestedPort) {
            return .badRequest(["error": "port_out_of_range"])
        }

        await MainActor.run {
            if let requestedPort = requestedPort {
                app.settings.settings.maaToolsPort = requestedPort
            }
            app.settings.settings.maaTools = true
        }

        let shouldRestart = body.boolValue("restart", defaultValue: true)
        if shouldRestart {
            let stopResponse = await stopApp(bundleIdentifier: bundleIdentifier, body: body)
            guard stopResponse.statusCode == 200 else { return stopResponse }
            let startResponse = await startApp(bundleIdentifier: bundleIdentifier, body: body)
            guard startResponse.statusCode == 200 else { return startResponse }

            let port = await MainActor.run {
                app.settings.settings.maaToolsPort
            }
            let opened = await waitForPortOpen(port: port, timeout: body.doubleValue("portTimeout", defaultValue: 15))
            if !opened {
                return .badRequest([
                    "error": "maatools_port_unavailable",
                    "status": await status(for: app)
                ])
            }
        }

        return .ok(await status(for: app))
    }

    private func waitForRunning(bundleIdentifier: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await MainActor.run(body: { runningApplication(bundleIdentifier: bundleIdentifier) != nil }) {
                return true
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

    private func waitForStopped(bundleIdentifier: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await MainActor.run(body: { runningApplication(bundleIdentifier: bundleIdentifier) == nil }) {
                return true
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

    private func waitForPortOpen(port: Int, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await PortProbe.isOpen(host: "127.0.0.1", port: port) {
                return true
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return false
    }
}

private struct AppSnapshot {
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

private extension Dictionary where Key == String, Value == Any {
    func boolValue(_ key: String, defaultValue: Bool) -> Bool {
        self[key] as? Bool ?? defaultValue
    }

    func doubleValue(_ key: String, defaultValue: Double) -> Double {
        if let value = self[key] as? Double {
            return value
        }
        if let value = self[key] as? Int {
            return Double(value)
        }
        return defaultValue
    }

    func intValue(_ key: String) -> Int? {
        if let value = self[key] as? Int {
            return value
        }
        if let value = self[key] as? Double {
            return Int(value)
        }
        return nil
    }
}
