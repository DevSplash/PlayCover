//
//  NativeScalingPreferences.swift
//  PlayCover
//

import Foundation

enum NativeScalingPreferences {
    static let scaleFactorKey = "iOSMacScaleFactor"
    static let lastUsedWindowScaleFactorKey = "UINSLastUsedWindowScaleFactor"

    enum Domain {
        case container(URL)
        case bundleSuite(String)

        var suiteName: String {
            switch self {
            case .container(let url):
                return url.path
            case .bundleSuite(let identifier):
                return identifier
            }
        }

        var kind: String {
            switch self {
            case .container:
                return "container"
            case .bundleSuite:
                return "bundle suite"
            }
        }
    }

    private struct DomainSnapshot {
        let domain: Domain
        let scaleFactor: CFPropertyList?
        let lastUsedWindowScaleFactor: CFPropertyList?
    }

    @discardableResult
    static func apply(bundleIdentifier: String,
                      container: AppContainer,
                      enabled: Bool) -> Bool {
        apply(bundleIdentifier: bundleIdentifier,
              container: container,
              enabled: enabled,
              commit: { true })
    }

    static func apply(bundleIdentifier: String,
                      container: AppContainer,
                      enabled: Bool,
                      commit: () -> Bool) -> Bool {
        let targetDomains = domains(bundleIdentifier: bundleIdentifier, container: container)
        var snapshots: [DomainSnapshot] = []
        for domain in targetDomains {
            guard let snapshot = snapshot(domain,
                                           bundleIdentifier: bundleIdentifier,
                                           enabled: enabled) else {
                return false
            }
            snapshots.append(snapshot)
        }

        for domain in targetDomains {
            guard apply(to: domain,
                        bundleIdentifier: bundleIdentifier,
                        enabled: enabled) else {
                restore(snapshots, bundleIdentifier: bundleIdentifier)
                return false
            }
        }

        guard commit() else {
            restore(snapshots, bundleIdentifier: bundleIdentifier)
            return false
        }
        return true
    }

    static func isEnabled(bundleIdentifier: String, container: AppContainer) -> Bool {
        isEnabled(in: preferredDomain(bundleIdentifier: bundleIdentifier, container: container))
    }
}

private extension NativeScalingPreferences {
    static func preferredDomain(bundleIdentifier: String, container: AppContainer) -> Domain {
        if container.doesExist() {
            return .container(container.userPrefsUrl)
        }
        return .bundleSuite(bundleIdentifier)
    }

    static func domains(bundleIdentifier: String, container: AppContainer) -> [Domain] {
        var result: [Domain] = []
        if container.doesExist() {
            result.append(.container(container.userPrefsUrl))
        }
        result.append(.bundleSuite(bundleIdentifier))
        return result
    }

    private static func snapshot(_ domain: Domain,
                                 bundleIdentifier: String,
                                 enabled: Bool) -> DomainSnapshot? {
        if let reason = prepare(domain) {
            logFailure(bundleIdentifier: bundleIdentifier,
                       domain: domain,
                       enabled: enabled,
                       reason: reason)
            return nil
        }
        guard synchronize(domain) else {
            logFailure(bundleIdentifier: bundleIdentifier,
                       domain: domain,
                       enabled: enabled,
                       reason: "unable to synchronize before snapshot")
            return nil
        }
        return DomainSnapshot(
            domain: domain,
            scaleFactor: cfValue(scaleFactorKey, domain: domain),
            lastUsedWindowScaleFactor: cfValue(lastUsedWindowScaleFactorKey, domain: domain)
        )
    }

    @discardableResult
    private static func restore(_ snapshots: [DomainSnapshot], bundleIdentifier: String) -> Bool {
        let results = snapshots.map { snapshot in
            if let reason = prepare(snapshot.domain) {
                logRollbackFailure(bundleIdentifier: bundleIdentifier,
                                   domain: snapshot.domain,
                                   reason: reason)
                return false
            }

            setCFValue(lastUsedWindowScaleFactorKey,
                       snapshot.lastUsedWindowScaleFactor,
                       domain: snapshot.domain)
            setCFValue(scaleFactorKey, snapshot.scaleFactor, domain: snapshot.domain)
            let synchronized = synchronize(snapshot.domain)
            let verified = verify(snapshot, in: snapshot.domain)
            if !synchronized || !verified {
                logRollbackFailure(
                    bundleIdentifier: bundleIdentifier,
                    domain: snapshot.domain,
                    reason: "sync=\(synchronized) readback=\(verified)"
                )
            }
            return synchronized && verified
        }
        return results.allSatisfy { $0 }
    }

    static func apply(to domain: Domain,
                      bundleIdentifier: String,
                      enabled: Bool) -> Bool {
        if let reason = prepare(domain) {
            logFailure(bundleIdentifier: bundleIdentifier,
                       domain: domain,
                       enabled: enabled,
                       reason: reason)
            return false
        }

        write(enabled, to: domain)
        let synchronized = synchronize(domain)
        let verified = verify(enabled, in: domain)
        logResult(bundleIdentifier: bundleIdentifier,
                  domain: domain,
                  enabled: enabled,
                  synchronized: synchronized,
                  verified: verified)
        return synchronized && verified
    }

    static func write(_ enabled: Bool, to domain: Domain) {
        if enabled {
            setCFValue(lastUsedWindowScaleFactorKey, nil, domain: domain)
            setCFValue(scaleFactorKey, 1 as CFNumber, domain: domain)
        } else {
            let lastUsedIsNative = isNativeScale(
                cfValue(lastUsedWindowScaleFactorKey, domain: domain)
            )
            setCFValue(scaleFactorKey, nil, domain: domain)
            if lastUsedIsNative {
                setCFValue(lastUsedWindowScaleFactorKey, nil, domain: domain)
            }
        }
    }

    static func verify(_ enabled: Bool, in domain: Domain) -> Bool {
        let scaleFactor = cfValue(scaleFactorKey, domain: domain)
        let lastUsedScaleFactor = cfValue(lastUsedWindowScaleFactorKey, domain: domain)
        if enabled {
            return isNativeScale(scaleFactor) && lastUsedScaleFactor == nil
        }
        return scaleFactor == nil && !isNativeScale(lastUsedScaleFactor)
    }

    private static func verify(_ snapshot: DomainSnapshot, in domain: Domain) -> Bool {
        propertyListValuesEqual(snapshot.scaleFactor, cfValue(scaleFactorKey, domain: domain)) &&
            propertyListValuesEqual(
                snapshot.lastUsedWindowScaleFactor,
                cfValue(lastUsedWindowScaleFactorKey, domain: domain)
            )
    }

    static func isEnabled(in domain: Domain) -> Bool {
        isNativeScale(cfValue(scaleFactorKey, domain: domain))
    }

    static func isNativeScale(_ value: Any?) -> Bool {
        (value as? NSNumber)?.doubleValue == 1
    }

    static func setCFValue(_ key: String, _ value: CFPropertyList?, domain: Domain) {
        CFPreferencesSetValue(key as CFString,
                              value,
                              domain.suiteName as CFString,
                              kCFPreferencesCurrentUser,
                              kCFPreferencesAnyHost)
    }

    static func cfValue(_ key: String, domain: Domain) -> CFPropertyList? {
        CFPreferencesCopyValue(key as CFString,
                               domain.suiteName as CFString,
                               kCFPreferencesCurrentUser,
                               kCFPreferencesAnyHost)
    }

    static func synchronize(_ domain: Domain) -> Bool {
        CFPreferencesSynchronize(
            domain.suiteName as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
    }

    static func propertyListValuesEqual(_ lhs: CFPropertyList?,
                                        _ rhs: CFPropertyList?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return CFEqual(lhs, rhs)
        default:
            return false
        }
    }

    static func prepare(_ domain: Domain) -> String? {
        guard case .container(let url) = domain else {
            return nil
        }

        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
            } catch {
                return "preference directory not writable: \(error.localizedDescription)"
            }
        }
        return nil
    }

    static func logResult(bundleIdentifier: String,
                          domain: Domain,
                          enabled: Bool,
                          synchronized: Bool,
                          verified: Bool) {
        let state = enabled ? "enable" : "disable"
        Log.shared.log(
            "Native scaling \(state) bundle=\(bundleIdentifier) domain=\(domain.kind) " +
            "sync=\(synchronized) readback=\(verified)"
        )
        if !synchronized || !verified {
            Log.shared.log(
                "Native scaling preference write did not verify for \(bundleIdentifier); " +
                "this does not mean macOS adopted the setting",
                isError: true
            )
        }
    }

    static func logFailure(bundleIdentifier: String,
                           domain: Domain,
                           enabled: Bool,
                           reason: String) {
        let state = enabled ? "enable" : "disable"
        Log.shared.log(
            "Native scaling \(state) failed bundle=\(bundleIdentifier) " +
            "domain=\(domain.kind): \(reason)",
            isError: true
        )
    }

    static func logRollbackFailure(bundleIdentifier: String,
                                   domain: Domain,
                                   reason: String) {
        Log.shared.log(
            "Native scaling rollback failed bundle=\(bundleIdentifier) " +
            "domain=\(domain.kind): \(reason)",
            isError: true
        )
    }
}
