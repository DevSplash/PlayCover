//
//  ManagementSettings.swift
//  PlayCover
//

import SwiftUI

class ManagementPreferences: NSObject, ObservableObject {
    static let shared = ManagementPreferences()

    static let defaultHost = "127.0.0.1"
    static let defaultPort = 1718

    enum Keys {
        static let enabled = "ManagementServerEnabled"
        static let host = "ManagementServerHost"
        static let port = "ManagementServerPort"
        static let key = "ManagementServerKey"
    }

    @AppStorage(Keys.enabled) var enabled = false
    @AppStorage(Keys.host) var host = ManagementPreferences.defaultHost
    @AppStorage(Keys.port) var port = ManagementPreferences.defaultPort
    @AppStorage(Keys.key) var key = ""

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Keys.enabled: false,
            Keys.host: defaultHost,
            Keys.port: defaultPort,
            Keys.key: ""
        ])
    }
}

struct ManagementSettings: View {
    public static var shared = ManagementSettings()

    @ObservedObject var preferences = ManagementPreferences.shared
    @State private var draftHost = ManagementPreferences.shared.host
    @State private var draftPort = ManagementPreferences.shared.port
    @State private var draftKey = ManagementPreferences.shared.key
    @State private var showApplied = false
    @State private var applyError: LocalizedStringKey?

    private static var portFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 1
        formatter.maximum = 65535
        return formatter
    }

    private var hasPendingChanges: Bool {
        draftHost != preferences.host ||
            draftPort != preferences.port ||
            draftKey != preferences.key
    }

    private var applyButtonTitle: LocalizedStringKey {
        showApplied ? "preferences.status.applied" : "button.Apply"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("preferences.toggle.managementServer", isOn: Binding(
                get: { preferences.enabled },
                set: setEnabled
            ))

            settingsRow("preferences.text.listenIP") {
                TextField("", text: $draftHost)
                    .frame(width: 220)
                    .onSubmit {
                        applyChanges()
                    }
                    .onChange(of: draftHost) { _ in
                        clearStatus()
                    }
            }

            settingsRow("preferences.text.port") {
                Stepper(value: $draftPort, in: 1 ... 65535) {
                    TextField("", value: $draftPort, formatter: ManagementSettings.portFormatter)
                        .frame(width: 100)
                }
                .onChange(of: draftPort) { _ in
                    clearStatus()
                }
            }

            settingsRow("preferences.text.accessKey") {
                SecureField("preferences.text.emptyAccessKey", text: $draftKey)
                    .frame(width: 220)
                    .onChange(of: draftKey) { _ in
                        clearStatus()
                    }
            }

            HStack {
                if let applyError = applyError {
                    Text(applyError)
                        .foregroundColor(.red)
                }
                Spacer()
                Button(applyButtonTitle) {
                    applyChanges()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasPendingChanges)
            }
        }
        .padding(30)
        .frame(width: 600, height: 250, alignment: .topLeading)
        .onAppear {
            draftHost = preferences.host
            draftPort = preferences.port
            draftKey = preferences.key
            clearStatus()
        }
    }

    private func settingsRow<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            Text(title)
                .frame(width: 120, alignment: .leading)
            content()
            Spacer()
        }
    }

    private func applyChanges() {
        guard hasPendingChanges else { return }

        if preferences.enabled {
            ManagementServer.shared.start(host: draftHost, port: draftPort) { result in
                if applyResult(result) {
                    saveDrafts()
                }
            }
        } else {
            saveDrafts()
            applyResult(.applied)
        }
    }

    private func setEnabled(_ enabled: Bool) {
        clearStatus()

        if enabled {
            ManagementServer.shared.start(host: draftHost, port: draftPort) { result in
                if applyResult(result) {
                    saveDrafts()
                    preferences.enabled = true
                }
            }
        } else {
            preferences.enabled = false
            ManagementServer.shared.stop { result in
                applyResult(result)
            }
        }
    }

    @discardableResult
    private func applyResult(_ result: ManagementServerApplyResult) -> Bool {
        switch result {
        case .applied, .stopped:
            showApplied = true
            applyError = nil
            return true
        case let .failed(error):
            showApplied = false
            applyError = message(for: error)
            return false
        }
    }

    private func message(for error: ManagementServerApplyError) -> LocalizedStringKey {
        switch error {
        case .portInUse:
            return "preferences.status.portInUse"
        case .invalidHost:
            return "preferences.status.invalidListenIP"
        case .portOutOfRange:
            return "preferences.status.portOutOfRange"
        case .socketCreationFailed, .bindFailed, .listenFailed:
            return "preferences.status.applyFailed"
        }
    }

    private func saveDrafts() {
        preferences.host = draftHost
        preferences.port = draftPort
        preferences.key = draftKey
    }

    private func clearStatus() {
        showApplied = false
        applyError = nil
    }
}
