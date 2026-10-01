import Foundation
import ServiceManagement
import NotchBuddyCore

/// Thin wrapper over `SMAppService.mainApp`. Only works when running from a real .app bundle.
enum LaunchAtLogin {
    enum State: Equatable {
        case enabled
        case disabled
        /// Registered, but the user has to allow it in System Settings → Login Items.
        case requiresApproval
        /// Running unbundled (`swift run`): SMAppService can't register a bare executable.
        case unavailable
    }

    enum Failure: Error, CustomStringConvertible {
        case notBundled
        case system(Error)

        var description: String {
            switch self {
            case .notBundled:
                return L("Автозапуск работает только для приложения NotchBuddy.app (не для swift run).")
            case .system(let error):
                return error.localizedDescription
            }
        }
    }

    static var isBundled: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    static var state: State {
        guard isBundled else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .disabled
        @unknown default: return .disabled
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        guard isBundled else { throw Failure.notBundled }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            throw Failure.system(error)
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
