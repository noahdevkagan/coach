import SwiftUI

/// First-run empty state for the main pane: a live checklist that gets a
/// new person to their first coached meeting — permissions, the two model
/// downloads (already running, with real progress), then "join a meeting".
/// Replaces the old demo-centric card; the demo survives as a footer link.
struct OnboardingChecklistView: View {
    var liveSession: LiveSessionViewModel?
    var settings: SettingsViewModel?

    @Environment(\.openSettings) private var openSettings
    @State private var micState = PermissionStatus.microphone
    @State private var screenState = PermissionStatus.screenRecording
    // TCC has no change notifications — poll while visible so rows flip
    // moments after the user grants in the system dialog / System Settings.
    private let permissionPoll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var download: ParakeetDownloadState { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 4) {
                Text("Get set up for your first meeting")
                    .font(Dorado.barlowXBold(22))
                    .foregroundStyle(Dorado.midnight)
                    .frame(maxWidth: .infinity)
                Text("Two permissions, two downloads — then it's automatic.")
                    .font(Dorado.roboto(13))
                    .foregroundStyle(Dorado.grey500)
                    .frame(maxWidth: .infinity)
            }

            microphoneRow
            screenRecordingRow
            transcriptionRow
            coachModelRow
            joinMeetingRow

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text("Audio is never stored. Transcripts, models, coaching — everything stays on this Mac.")
                        .font(Dorado.roboto(12))
                        .foregroundStyle(Dorado.grey600)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(Dorado.dollar)
                }
                if let liveSession {
                    Button("Curious what a nudge looks like? Watch the 15-second demo") {
                        liveSession.startDemo()
                    }
                    .buttonStyle(.plain)
                    .font(Dorado.roboto(13))
                    .foregroundStyle(Dorado.bolt)
                }
                Button("Coming from Granola? Import your meetings") {
                    openSettings()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.blue)
            }
        }
        .padding(28)
        .frame(maxWidth: 440)
        .background(RoundedRectangle(cornerRadius: 12).fill(Dorado.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Dorado.border, lineWidth: 1))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .onAppear(perform: refreshPermissions)
        .onReceive(permissionPoll) { _ in refreshPermissions() }
    }

    private func refreshPermissions() {
        micState = PermissionStatus.microphone
        screenState = PermissionStatus.screenRecording
    }

    // MARK: - Rows

    private var microphoneRow: some View {
        checklistRow(done: micState == .granted,
                     title: "Microphone access",
                     caption: micState == .denied
                         ? "Denied — enable MeetingCoach in System Settings."
                         : "So the coach can hear your side of the call.") {
            if micState != .granted {
                Button(micState == .denied ? "Open Settings" : "Grant") {
                    PermissionStatus.requestMicrophone { refreshPermissions() }
                }
                .font(.caption)
            }
        } detail: {
            EmptyView()
        }
    }

    private var screenRecordingRow: some View {
        checklistRow(done: screenState == .granted,
                     title: "Screen Recording",
                     caption: "How macOS lets us hear the other side of the call. Nothing is recorded or stored.") {
            if screenState != .granted {
                Button("Grant") {
                    PermissionStatus.requestScreenRecording()
                }
                .font(.caption)
            }
        } detail: {
            EmptyView()
        }
    }

    private var transcriptionRow: some View {
        checklistRow(done: download.isReady,
                     active: download.isActive,
                     title: "Transcription engine",
                     caption: "High-accuracy, on-device (~600 MB). Downloads automatically.") {
            EmptyView()
        } detail: {
            ParakeetProgressLine()
        }
    }

    @ViewBuilder private var coachModelRow: some View {
        let hasModel = settings.map { !$0.availableModels.isEmpty } ?? false
        let downloading = settings?.downloadingModel != nil
        checklistRow(done: hasModel,
                     active: downloading,
                     title: "AI coach model",
                     titleBadge: "optional",
                     caption: "Smarter nudges + meeting reviews. 100% local (\(recommendedCatalogModel.diskSize)).") {
            if let settings, !hasModel {
                if downloading {
                    Button("Cancel") { settings.cancelDownload() }
                        .font(.caption)
                } else if UserDefaults.standard.bool(forKey: SettingsViewModel.autoModelPullAttemptedKey) {
                    Button("Download") { settings.downloadModel(recommendedCatalogModel) }
                        .font(.caption)
                }
            }
        } detail: {
            if let settings, !hasModel {
                if downloading {
                    VStack(alignment: .leading, spacing: 2) {
                        ProgressView(value: settings.downloadProgress)
                            .controlSize(.small)
                        Text(settings.downloadStatus)
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                } else if let error = settings.downloadError {
                    Text(error)
                        .font(.caption2).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !download.isReady {
                    Text("Queued — starts after the transcription engine.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var joinMeetingRow: some View {
        checklistRow(done: false,
                     active: liveSession?.isLive == true,
                     title: liveSession?.isLive == true ? "You're live!" : "Join a meeting",
                     caption: "We detect Zoom & Meet and offer to start — or click Go Live any time.") {
            EmptyView()
        } detail: {
            EmptyView()
        }
    }

    // MARK: - Row scaffolding

    private func checklistRow(done: Bool, active: Bool = false,
                              title: String, titleBadge: String? = nil,
                              caption: String,
                              @ViewBuilder trailing: () -> some View,
                              @ViewBuilder detail: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Dorado.dollar)
                } else if active {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(Color(hex: 0xC7CED7))
                }
            }
            .font(.system(size: 18))
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(Dorado.barlowBold(15)).foregroundStyle(Dorado.midnight)
                    if let titleBadge {
                        Text(titleBadge)
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Dorado.surfaceSubtle)
                            .foregroundStyle(Dorado.grey600)
                            .clipShape(Capsule())
                    }
                }
                Text(caption)
                    .font(Dorado.roboto(13))
                    .foregroundStyle(Dorado.grey600)
                    .fixedSize(horizontal: false, vertical: true)
                detail()
            }

            Spacer(minLength: 0)
            trailing()
        }
    }
}

/// Compact live status for the Parakeet download, shared by the onboarding
/// checklist and the reduced-accuracy session banners. Renders nothing when
/// there is nothing to say (idle or already downloaded).
struct ParakeetProgressLine: View {
    private var download: ParakeetDownloadState { .shared }

    var body: some View {
        switch download.phase {
        case .downloading(let fraction, let detail):
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: fraction)
                    .controlSize(.small)
                Text("\(Int(fraction * 100))%\(detail.isEmpty ? "" : " · \(detail)")")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        case .compiling:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Optimizing for this Mac…")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        case .failed(let message):
            HStack(spacing: 6) {
                Text("Download failed: \(message)")
                    .font(.caption2).foregroundStyle(.red)
                    .lineLimit(2)
                Button("Retry") { download.retry() }
                    .font(.caption2)
            }
        case .idle, .ready:
            EmptyView()
        }
    }
}
