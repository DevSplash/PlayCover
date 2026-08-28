//
//  ManagementServer+Routing.swift
//  PlayCover
//

import AppKit
import Foundation

private actor ManagementAppOperationRegistry {
    static let shared = ManagementAppOperationRegistry()

    private var activeBundleIdentifiers = Set<String>()

    func acquire(_ bundleIdentifier: String) -> Bool {
        activeBundleIdentifiers.insert(bundleIdentifier).inserted
    }

    func release(_ bundleIdentifier: String) {
        activeBundleIdentifiers.remove(bundleIdentifier)
    }
}

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
            return await withAppOperation(bundleIdentifier: segments[1]) {
                await self.startApp(bundleIdentifier: segments[1], body: request.jsonBody)
            }
        case ("POST", 3) where segments[2] == "stop":
            return await withAppOperation(bundleIdentifier: segments[1]) {
                await self.stopApp(bundleIdentifier: segments[1], body: request.jsonBody)
            }
        case ("POST", 3) where segments[2] == "restart":
            return await withAppOperation(bundleIdentifier: segments[1]) {
                await self.restartApp(bundleIdentifier: segments[1], body: request.jsonBody)
            }
        case ("POST", 4) where segments[2] == "maatools" && segments[3] == "open":
            return await withAppOperation(bundleIdentifier: segments[1]) {
                await self.openMaaTools(bundleIdentifier: segments[1], body: request.jsonBody)
            }
        default:
            return .notFound(["error": "not_found"])
        }
    }

    private func withAppOperation(bundleIdentifier: String,
                                  operation: () async -> ManagementResponse) async -> ManagementResponse {
        guard await ManagementAppOperationRegistry.shared.acquire(bundleIdentifier) else {
            return .conflict(["error": "app_operation_in_progress"])
        }
        let response = await operation()
        await ManagementAppOperationRegistry.shared.release(bundleIdentifier)
        return response
    }

    private func appsResponse() async -> ManagementResponse {
        let apps = await installedApps()
        let snapshots = await MainActor.run {
            let runningApps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
            return apps.map { app in
                appSnapshot(for: app, runningApp: runningApps.first {
                    $0.bundleIdentifier == app.info.bundleIdentifier
                })
            }
        }
        let summaries = snapshots
            .sorted { $0.bundleIdentifier < $1.bundleIdentifier }
            .map { $0.summaryDictionary() }
        return .ok(["apps": summaries])
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

    func installedApp(bundleIdentifier: String) async -> PlayApp? {
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

    func status(for app: PlayApp, verifyMaaTools: Bool = true) async -> [String: Any] {
        let snapshot = await MainActor.run {
            appSnapshot(for: app, runningApp: runningApplication(bundleIdentifier: app.info.bundleIdentifier))
        }

        let shouldProbe = verifyMaaTools && snapshot.maaToolsEnabled && snapshot.running
        let probe = shouldProbe
            ? await MaaToolsProbe.inspect(host: "127.0.0.1", port: snapshot.maaToolsPort)
            : nil

        return snapshot.dictionary(probe: probe)
    }

    @MainActor
    private func appSnapshot(for app: PlayApp, runningApp: NSRunningApplication?) -> AppSnapshot {
        AppSnapshot(
            bundleIdentifier: app.info.bundleIdentifier,
            name: app.name,
            running: runningApp != nil,
            pid: runningApp?.processIdentifier,
            maaToolsEnabled: app.settings.settings.maaTools,
            maaToolsPort: app.settings.settings.maaToolsPort
        )
    }

    @MainActor
    func runningApplication(bundleIdentifier: String) -> NSRunningApplication? {
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

        let launchResult = await app.launch(runningTimeout: timeout)
        let started = launchResult.runningApplication.map { !$0.isTerminated } ?? false
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

    func stopApp(bundleIdentifier: String, body: ManagementBody) async -> ManagementResponse {
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

    func waitForStopped(bundleIdentifier: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await MainActor.run(body: { runningApplication(bundleIdentifier: bundleIdentifier) == nil }) {
                return true
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

}
