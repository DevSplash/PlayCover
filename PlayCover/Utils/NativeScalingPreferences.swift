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

    static func preferredDomain(bundleIdentifier: String,
                                container: AppContainer) -> Domain {
        if container.doesExist() {
            return .container(container.userPrefsUrl)
        }
        return .bundleSuite(bundleIdentifier)
    }

    @discardableResult
    static func apply(bundleIdentifier: String,
                      container: AppContainer,
                      enabled: Bool) -> Bool {
        let domain = preferredDomain(bundleIdentifier: bundleIdentifier,
                                     container: container)
        if let reason = prepare(domain) {
            logFailure(bundleIdentifier: bundleIdentifier,
                       domain: domain,
                       enabled: enabled,
                       reason: reason)
            return false
        }

        guard let defaults = UserDefaults(suiteName: domain.suiteName) else {
            logFailure(bundleIdentifier: bundleIdentifier,
                       domain: domain,
                       enabled: enabled,
                       reason: "preference domain unavailable")
            return false
        }

        write(enabled, to: defaults)
        let synchronized = defaults.synchronize()
        CFPreferencesSynchronize(domain.suiteName as CFString,
                                 kCFPreferencesCurrentUser,
                                 kCFPreferencesAnyHost)
        let verified = verify(enabled, in: defaults, domain: domain)
        logResult(bundleIdentifier: bundleIdentifier,
                  domain: domain,
                  enabled: enabled,
                  synchronized: synchronized,
                  verified: verified)
        return synchronized && verified
    }

    static func isEnabled(bundleIdentifier: String, container: AppContainer) -> Bool {
        let domain = preferredDomain(bundleIdentifier: bundleIdentifier,
                                     container: container)
        if let defaults = UserDefaults(suiteName: domain.suiteName),
           matches(true, defaults.object(forKey: scaleFactorKey)) {
            return true
        }

        let copied = CFPreferencesCopyValue(scaleFactorKey as CFString,
                                            domain.suiteName as CFString,
                                            kCFPreferencesCurrentUser,
                                            kCFPreferencesAnyHost)
        return matches(true, copied)
    }
}

private extension NativeScalingPreferences {
    static func write(_ enabled: Bool, to defaults: UserDefaults) {
        if enabled {
            defaults.setValue(nil, forKey: lastUsedWindowScaleFactorKey)
            defaults.setValue(1, forKey: scaleFactorKey)
        } else {
            defaults.setValue(nil, forKey: scaleFactorKey)
        }
    }

    static func verify(_ enabled: Bool,
                       in defaults: UserDefaults,
                       domain: Domain) -> Bool {
        if matches(enabled, defaults.object(forKey: scaleFactorKey)) {
            return true
        }

        let copied = CFPreferencesCopyValue(scaleFactorKey as CFString,
                                            domain.suiteName as CFString,
                                            kCFPreferencesCurrentUser,
                                            kCFPreferencesAnyHost)
        return matches(enabled, copied)
    }

    static func matches(_ enabled: Bool, _ value: Any?) -> Bool {
        if enabled {
            return (value as? NSNumber)?.doubleValue == 1
        }
        return value == nil
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
}
