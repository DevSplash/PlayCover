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

    private func restartApp(bundleIdentifier: String, body: ManagementBody) async -> ManagementResponse {
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

    private func startApp(bundleIdentifier: String, body: ManagementBody) async -> ManagementResponse {
        guard let app = await installedApp(bundleIdentifier: bundleIdentifier) else {
            return .notFound(["error": "app_not_found"])
        }
        guard let timeout = body.timeoutValue("timeout", defaultValue: 15) else {
            return .badRequest(["error": "timeout_out_of_range"])
        }

        if await MainActor.run(body: { runningApplication(bundleIdentifier: bundleIdentifier) != nil }) {
            return .ok(await status(for: app))
        }

        await app.launch()
        let started = await waitForRunning(bundleIdentifier: bundleIdentifier, timeout: timeout)
        guard started else {
            return .gatewayTimeout([
                "error": "app_start_timeout",
                "status": await status(for: app)
            ])
        }
        let currentStatus = await status(for: app)
        guard currentStatus["running"] as? Bool == true else {
            return .gatewayTimeout([
                "error": "app_start_timeout",
                "status": currentStatus
            ])
        }
        return .ok(currentStatus)
    }

    private func stopApp(bundleIdentifier: String, body: ManagementBody) async -> ManagementResponse {
        guard let app = await installedApp(bundleIdentifier: bundleIdentifier) else {
            return .notFound(["error": "app_not_found"])
        }
        guard let timeout = body.timeoutValue("timeout", defaultValue: 10) else {
            return .badRequest(["error": "timeout_out_of_range"])
        }

        guard let runningApp = await MainActor.run(body: {
            runningApplication(bundleIdentifier: bundleIdentifier)
        }) else {
            return .ok(await status(for: app))
        }

        let force = body.boolValue("force", defaultValue: false)

        _ = await MainActor.run {
            if force {
                runningApp.forceTerminate()
            } else {
                runningApp.terminate()
            }
        }

        var stopped: Bool
        if !force {
            stopped = await waitForStopped(bundleIdentifier: bundleIdentifier, timeout: timeout)
            if !stopped {
                _ = await MainActor.run {
                    runningApp.forceTerminate()
                }
                stopped = await waitForStopped(bundleIdentifier: bundleIdentifier, timeout: 5)
            }
        } else {
            stopped = await waitForStopped(bundleIdentifier: bundleIdentifier, timeout: timeout)
        }

        guard stopped else {
            return .gatewayTimeout([
                "error": "app_stop_timeout",
                "status": await status(for: app)
            ])
        }

        let currentStatus = await status(for: app)
        guard currentStatus["running"] as? Bool == false else {
            return .gatewayTimeout([
                "error": "app_stop_timeout",
                "status": currentStatus
            ])
        }
        return .ok(currentStatus)
    }

    private func openMaaTools(bundleIdentifier: String, body: ManagementBody) async -> ManagementResponse {
        guard let app = await installedApp(bundleIdentifier: bundleIdentifier) else {
            return .notFound(["error": "app_not_found"])
        }

        let requestedPort = body.intValue("port")
        if body["port"] != nil && requestedPort == nil {
            return .badRequest(["error": "invalid_port"])
        }
        if let requestedPort = requestedPort, !(1024 ... 65535).contains(requestedPort) {
            return .badRequest(["error": "port_out_of_range"])
        }
        guard let portTimeout = body.timeoutValue("portTimeout", defaultValue: 15) else {
            return .badRequest(["error": "port_timeout_out_of_range"])
        }

        let previousSettings = await MainActor.run {
            MaaToolsSettingsSnapshot(
                enabled: app.settings.settings.maaTools,
                port: app.settings.settings.maaToolsPort
            )
        }
        let port = requestedPort ?? previousSettings.port
        let appIsRunning = await MainActor.run {
            runningApplication(bundleIdentifier: bundleIdentifier) != nil
        }

        if await PortProbe.isOpen(host: "127.0.0.1", port: port) {
            let probe = await MaaToolsProbe.inspect(
                host: "127.0.0.1",
                port: port,
                expectedBundleIdentifier: bundleIdentifier
            )
            let mayBeBusyTarget = appIsRunning && previousSettings.enabled && previousSettings.port == port
            if probe == nil && !mayBeBusyTarget {
                return .conflict(["error": "maatools_port_in_use"])
            }
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
            guard stopResponse.statusCode == 200 else {
                await restoreMaaToolsSettings(previousSettings, for: app)
                return stopResponse
            }
            let startResponse = await startApp(bundleIdentifier: bundleIdentifier, body: body)
            guard startResponse.statusCode == 200 else {
                await restoreMaaToolsSettings(previousSettings, for: app)
                return startResponse
            }

            let probe = await waitForMaaTools(
                bundleIdentifier: bundleIdentifier,
                port: port,
                timeout: portTimeout
            )
            if probe == nil {
                await restoreMaaToolsSettings(previousSettings, for: app)
                return .gatewayTimeout([
                    "error": "maatools_port_unavailable",
                    "status": await status(for: app)
                ])
            }
        }

        return .ok(await status(for: app))
    }

    private func restoreMaaToolsSettings(_ snapshot: MaaToolsSettingsSnapshot, for app: PlayApp) async {
        await MainActor.run {
            app.settings.settings.maaTools = snapshot.enabled
            app.settings.settings.maaToolsPort = snapshot.port
        }
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

    private func waitForMaaTools(bundleIdentifier: String,
                                 port: Int,
                                 timeout: TimeInterval) async -> MaaToolsProbeResult? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let result = await MaaToolsProbe.inspect(
                host: "127.0.0.1",
                port: port,
                expectedBundleIdentifier: bundleIdentifier
            ) {
                Log.shared.log(
                    "Verified MaaTools v\(result.version) for \(result.bundleIdentifier) on port \(port)"
                )
                return result
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return nil
    }
}
