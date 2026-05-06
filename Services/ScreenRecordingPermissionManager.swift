import AppKit
import CoreGraphics
import ScreenCaptureKit

enum ScreenRecordingState {
    case unknown
    case notDetermined
    case denied
    case grantedStale
    case granted
}

@MainActor
final class ScreenRecordingPermissionManager: ObservableObject {
    static let shared = ScreenRecordingPermissionManager()

    @Published private(set) var state: ScreenRecordingState = .unknown

    private let defaults = UserDefaults.standard
    private var didBecomeActiveObserver: NSObjectProtocol?

    private init() {
        startMonitoring()
    }

    // MARK: - Public API

    @discardableResult
    func checkPermission() async -> ScreenRecordingState {
        let newState = await performCheck()
        state = newState

        if newState == .granted {
            defaults.set(true, forKey: Constants.UserDefaultsKeys.screenRecordingWasEverGranted)
            defaults.set(Date().timeIntervalSince1970, forKey: Constants.UserDefaultsKeys.screenRecordingLastGrantDate)
        }

        return newState
    }

    func requestPermission() {
        if !defaults.bool(forKey: Constants.UserDefaultsKeys.screenRecordingHasRequested) {
            defaults.set(true, forKey: Constants.UserDefaultsKeys.screenRecordingHasRequested)
        }
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        Task {
            try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
    }

    func openSettings() {
        AccessibilityService.openScreenRecordingSettings()
    }

    var wasEverGranted: Bool {
        defaults.bool(forKey: Constants.UserDefaultsKeys.screenRecordingWasEverGranted)
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.checkPermission()
            }
        }
    }

    // MARK: - Private

    private func performCheck() async -> ScreenRecordingState {
        if CGPreflightScreenCaptureAccess() {
            return .granted
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if !content.windows.isEmpty {
                return .granted
            }
        } catch {
            // SCShareableContent failed — permission denied or unavailable
        }

        if wasEverGranted {
            return .grantedStale
        }

        let hasRequested = defaults.bool(forKey: Constants.UserDefaultsKeys.screenRecordingHasRequested)
        return hasRequested ? .denied : .notDetermined
    }
}
