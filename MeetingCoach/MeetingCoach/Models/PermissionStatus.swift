import AppKit
import AVFoundation
import CoreGraphics

/// Read-only snapshots of the two capture permissions plus the actions the
/// onboarding checklist buttons take. TCC has no change notifications, so
/// callers poll (the checklist re-reads on a 2 s tick while visible).
enum PermissionStatus {
    enum State {
        case granted, notAsked, denied
    }

    static var microphone: State {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    /// First click fires the system prompt; once denied, the prompt never
    /// re-fires and System Settings is the only path.
    static func requestMicrophone(_ completion: @escaping @MainActor () -> Void) {
        if microphone == .notAsked {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in completion() }
            }
        } else {
            openPane("Privacy_Microphone")
        }
    }

    /// TCC exposes no asked/denied distinction for Screen Recording —
    /// preflight is a plain Bool, so !granted maps to notAsked and the
    /// button handles both ("ask, and if that can't prompt, open the pane").
    static var screenRecording: State {
        CGPreflightScreenCaptureAccess() ? .granted : .notAsked
    }

    static func requestScreenRecording() {
        // Returns true only when already granted; fires the one-time system
        // prompt otherwise. If no prompt is coming (already asked once),
        // the pane is the only path — open it.
        if !CGRequestScreenCaptureAccess() {
            openPane("Privacy_ScreenCapture")
        }
    }

    private static func openPane(_ anchor: String) {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}
