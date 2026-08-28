//
//  ManagementServer+MaaTools.swift
//  PlayCover
//

import AppKit
import Foundation

private enum ManagementFreshMode: String {
    case off
    case fallback
    case always
}

private enum ManagedLaunchOutcome: String {
    case ready
    case exitedBeforeReady
    case noProcess
    case requestFailed
    case maaToolsTimeout

    var allowsFreshFallback: Bool {
        self == .exitedBeforeReady || self == .noProcess
    }
}

private struct ManagedLaunchAttempt {
    let mode: PlayAppLaunchMode
    let outcome: ManagedLaunchOutcome
    let pid: pid_t?
    let elapsedMilliseconds: Int

    var dictionary: [String: Any] {
        let processIdentifier: Any
        if let pid = pid {
            processIdentifier = Int(pid)
        } else {
            processIdentifier = NSNull()
        }
        return [
            "mode": mode.rawValue,
            "outcome": outcome.rawValue,
            "pid": processIdentifier,
            "elapsedMs": elapsedMilliseconds
        ]
    }
}

private struct ManagedLaunchSummary {
    let requestedFresh: ManagementFreshMode
    let attempts: [ManagedLaunchAttempt]

    var dictionary: [String: Any] {
        [
            "requestedFresh": requestedFresh.rawValue,
            "effectiveMode": attempts.last?.mode.rawValue ?? PlayAppLaunchMode.normal.rawValue,
            "fallbackUsed": attempts.count > 1 && attempts.last?.mode == .fresh,
            "attemptCount": attempts.count,
            "attempts": attempts.map(\.dictionary)
        ]
    }
}

private struct MaaToolsLaunchContext {
    let app: PlayApp
    let bundleIdentifier: String
    let port: Int
    let launchTimeout: TimeInterval
    let portTimeout: TimeInterval
}

extension ManagementServer {
    func openMaaTools(bundleIdentifier: String, body: ManagementBody) async -> ManagementResponse {
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
        guard let launchTimeout = body.timeoutValue("timeout", defaultValue: 15) else {
            return .badRequest(["error": "timeout_out_of_range"])
        }
        guard let freshMode = freshMode(from: body) else {
            return .badRequest(["error": "invalid_fresh_mode"])
        }

        let shouldRestart = body.boolValue("restart", defaultValue: true)
        guard shouldRestart || freshMode == .off else {
            return .badRequest(["error": "fresh_requires_restart"])
        }

        let previousSettings = await maaToolsSettings(for: app)
        let port = requestedPort ?? previousSettings.port
        let context = MaaToolsLaunchContext(
            app: app,
            bundleIdentifier: bundleIdentifier,
            port: port,
            launchTimeout: launchTimeout,
            portTimeout: portTimeout
        )
        if let conflict = await portConflictResponse(context: context, previousSettings: previousSettings) {
            return conflict
        }

        guard shouldRestart else {
            await applyMaaToolsSettings(requestedPort: requestedPort, to: app)
            return .ok(await status(for: app))
        }

        return await restartMaaTools(
            context: context,
            body: body,
            requestedPort: requestedPort,
            previousSettings: previousSettings,
            freshMode: freshMode
        )
    }

    private func freshMode(from body: ManagementBody) -> ManagementFreshMode? {
        guard body["fresh"] != nil else { return .off }
        guard let value = body.stringValue("fresh") else { return nil }
        return ManagementFreshMode(rawValue: value)
    }

    private func maaToolsSettings(for app: PlayApp) async -> MaaToolsSettingsSnapshot {
        await MainActor.run {
            MaaToolsSettingsSnapshot(
                enabled: app.settings.settings.maaTools,
                port: app.settings.settings.maaToolsPort
            )
        }
    }

    private func portConflictResponse(context: MaaToolsLaunchContext,
                                      previousSettings: MaaToolsSettingsSnapshot) async -> ManagementResponse? {
        guard await PortProbe.isOpen(host: "127.0.0.1", port: context.port) else { return nil }

        if let probe = await MaaToolsProbe.inspect(host: "127.0.0.1", port: context.port) {
            guard probe.bundleIdentifier != context.bundleIdentifier else { return nil }
            return .conflict([
                "error": "maatools_port_in_use",
                "bundleIdentifier": probe.bundleIdentifier,
                "version": probe.version
            ])
        }

        let appIsRunning = await MainActor.run {
            runningApplication(bundleIdentifier: context.bundleIdentifier) != nil
        }
        let mayBeBusyTarget = appIsRunning && previousSettings.enabled && previousSettings.port == context.port
        guard !mayBeBusyTarget else { return nil }
        return .conflict(["error": "maatools_port_in_use"])
    }

    private func restartMaaTools(context: MaaToolsLaunchContext,
                                 body: ManagementBody,
                                 requestedPort: Int?,
                                 previousSettings: MaaToolsSettingsSnapshot,
                                 freshMode: ManagementFreshMode) async -> ManagementResponse {
        let stopResponse = await stopApp(bundleIdentifier: context.bundleIdentifier, body: body)
        guard stopResponse.statusCode == 200 else { return stopResponse }

        guard await waitForPortClosed(port: context.port, timeout: min(5, context.launchTimeout)) else {
            return .gatewayTimeout([
                "error": "maatools_port_did_not_close",
                "status": await status(for: context.app)
            ])
        }

        await applyMaaToolsSettings(requestedPort: requestedPort, to: context.app)
        let initialMode: PlayAppLaunchMode = freshMode == .always ? .fresh : .normal
        var attempts = [await launchMaaToolsAttempt(context: context, mode: initialMode)]

        if freshMode == .fallback && attempts[0].outcome.allowsFreshFallback {
            let appStopped = await waitForStopped(bundleIdentifier: context.bundleIdentifier, timeout: 5)
            let portClosed = await waitForPortClosed(port: context.port, timeout: 5)
            guard appStopped && portClosed else {
                let summary = ManagedLaunchSummary(requestedFresh: freshMode, attempts: attempts)
                await restoreMaaToolsSettings(previousSettings, for: context.app)
                return .gatewayTimeout([
                    "error": "fresh_fallback_cleanup_timeout",
                    "status": await status(for: context.app, launchSummary: summary)
                ])
            }
            attempts.append(await launchMaaToolsAttempt(context: context, mode: .fresh))
        }

        let summary = ManagedLaunchSummary(requestedFresh: freshMode, attempts: attempts)
        return await launchResponse(
            summary: summary,
            context: context,
            previousSettings: previousSettings
        )
    }

    private func applyMaaToolsSettings(requestedPort: Int?, to app: PlayApp) async {
        await MainActor.run {
            if let requestedPort = requestedPort {
                app.settings.settings.maaToolsPort = requestedPort
            }
            app.settings.settings.maaTools = true
        }
    }

    private func restoreMaaToolsSettings(_ snapshot: MaaToolsSettingsSnapshot, for app: PlayApp) async {
        await MainActor.run {
            app.settings.settings.maaTools = snapshot.enabled
            app.settings.settings.maaToolsPort = snapshot.port
        }
    }

    private func launchResponse(summary: ManagedLaunchSummary,
                                context: MaaToolsLaunchContext,
                                previousSettings: MaaToolsSettingsSnapshot) async -> ManagementResponse {
        guard let outcome = summary.attempts.last?.outcome else {
            await restoreMaaToolsSettings(previousSettings, for: context.app)
            return .serviceUnavailable(["error": "app_launch_failed"])
        }
        guard outcome != .ready else {
            return .ok(await status(for: context.app, launchSummary: summary))
        }

        await restoreMaaToolsSettings(previousSettings, for: context.app)
        let currentStatus = await status(for: context.app, launchSummary: summary)
        switch outcome {
        case .ready:
            return .ok(currentStatus)
        case .maaToolsTimeout:
            return .gatewayTimeout(["error": "maatools_port_unavailable", "status": currentStatus])
        case .exitedBeforeReady:
            return .serviceUnavailable(["error": "app_exited_before_maatools_ready", "status": currentStatus])
        case .noProcess:
            return .serviceUnavailable(["error": "app_start_timeout", "status": currentStatus])
        case .requestFailed:
            return .serviceUnavailable(["error": "app_launch_failed", "status": currentStatus])
        }
    }

    private func status(for app: PlayApp,
                        launchSummary: ManagedLaunchSummary) async -> [String: Any] {
        var currentStatus = await status(for: app)
        currentStatus["launch"] = launchSummary.dictionary
        return currentStatus
    }

    private func launchMaaToolsAttempt(context: MaaToolsLaunchContext,
                                       mode: PlayAppLaunchMode) async -> ManagedLaunchAttempt {
        let startedAt = Date()
        let launchResult = await context.app.launch(mode: mode, runningTimeout: context.launchTimeout)
        guard launchResult.requestAccepted else {
            return ManagedLaunchAttempt(
                mode: mode,
                outcome: .requestFailed,
                pid: nil,
                elapsedMilliseconds: milliseconds(since: startedAt)
            )
        }

        guard let runningApp = launchResult.runningApplication else {
            return ManagedLaunchAttempt(
                mode: mode,
                outcome: .noProcess,
                pid: nil,
                elapsedMilliseconds: milliseconds(since: startedAt)
            )
        }

        let outcome = await waitForMaaToolsOrExit(
            runningApp: runningApp,
            bundleIdentifier: context.bundleIdentifier,
            port: context.port,
            timeout: context.portTimeout
        )
        return ManagedLaunchAttempt(
            mode: mode,
            outcome: outcome,
            pid: runningApp.processIdentifier,
            elapsedMilliseconds: milliseconds(since: startedAt)
        )
    }

    private func waitForMaaToolsOrExit(runningApp: NSRunningApplication,
                                       bundleIdentifier: String,
                                       port: Int,
                                       timeout: TimeInterval) async -> ManagedLaunchOutcome {
        guard let deadline = SocketProbeDeadline(timeout: timeout) else {
            return runningApp.isTerminated ? .exitedBeforeReady : .maaToolsTimeout
        }
        while !deadline.isExpired {
            if runningApp.isTerminated {
                return .exitedBeforeReady
            }
            if let result = await MaaToolsProbe.inspect(
                host: "127.0.0.1",
                port: port,
                expectedBundleIdentifier: bundleIdentifier,
                within: deadline
            ) {
                guard !runningApp.isTerminated else { return .exitedBeforeReady }
                // Preserve the full stability interval; do not start it if the budget cannot cover it.
                guard deadline.remainingTime > 1 else { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !runningApp.isTerminated else { return .exitedBeforeReady }
                guard !deadline.isExpired else { break }
                guard await MaaToolsProbe.inspect(
                    host: "127.0.0.1",
                    port: port,
                    expectedBundleIdentifier: bundleIdentifier,
                    within: deadline
                ) != nil else {
                    continue
                }
                guard !runningApp.isTerminated else { return .exitedBeforeReady }
                guard !deadline.isExpired else { break }
                Log.shared.log(
                    "Verified MaaTools v\(result.version) for \(result.bundleIdentifier) on port \(port)"
                )
                return .ready
            }
            let remaining = deadline.remainingTime
            guard remaining > 0 else { break }
            try? await Task.sleep(nanoseconds: UInt64(min(0.3, remaining) * 1_000_000_000))
        }
        return runningApp.isTerminated ? .exitedBeforeReady : .maaToolsTimeout
    }

    private func waitForPortClosed(port: Int, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !(await PortProbe.isOpen(host: "127.0.0.1", port: port)) {
                return true
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return !(await PortProbe.isOpen(host: "127.0.0.1", port: port))
    }

    private func milliseconds(since date: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(date) * 1_000))
    }
}
