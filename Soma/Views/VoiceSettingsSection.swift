import SwiftUI

/// The Voice tab's Settings disclosure group. Lives in its own file only so
/// VoiceToTextView stays under the file-length ratchet; the token is still owned
/// by the parent, which reloads and persists it around this view's lifetime.
struct VoiceSettingsSection: View {
    @ObservedObject var asr: ASRManager
    @ObservedObject var globalVoice: GlobalVoiceController
    @Binding var voiceServerToken: String
    let voiceServerTokenError: String?

    @AppStorage("modelKeepLoadedMinutes") private var keepLoadedMinutes = 60
    @AppStorage("globalVoicePasteEnabled") private var globalVoicePasteEnabled = false
    @AppStorage("asrBackend") private var asrBackend = "local"
    @AppStorage("voiceServerURL") private var voiceServerURL = ""
    @AppStorage(ASRManager.retentionKey) private var retentionDays = ASRManager.defaultRetentionDays
    @State private var showSettings = false

    var body: some View {
        DisclosureGroup("Settings", isExpanded: $showSettings) {
            VStack(alignment: .leading, spacing: 12) {
                modelSettings
                Divider()
                retentionSettings
                Divider()
                backendSettings
                Divider()
                globalPasteSettings
            }
            .padding(.top, 8)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .frame(maxWidth: 640, alignment: .leading)
    }

    private var modelSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Stepper(value: $keepLoadedMinutes, in: 0...60) {
                Text("Keep model loaded when idle: **\(keepLoadedMinutes)** min")
            }
            Text("0 unloads immediately after each transcription. Higher values skip the slow reload on the next request.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var retentionSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Delete recordings older than", selection: $retentionDays) {
                Text("14 days").tag(14)
                Text("1 month").tag(30)
                Text("3 months").tag(90)
                Text("6 months").tag(180)
                Text("1 year").tag(365)
                Text("Never").tag(0)
            }
            // Sweeping on change, not only at launch, so shortening the window
            // does something visible instead of waiting for the next start.
            .onChange(of: retentionDays) { _, _ in asr.pruneOldRecordings() }
            Text("Applies to the audio and its transcript together. \"Never\" keeps everything — the library grows without bound.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var backendSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Transcription backend", selection: $asrBackend) {
                Text("Local Mac").tag("local")
                Text("M1 Server").tag("remote")
            }
            .pickerStyle(.segmented)
            .disabled(asr.isRecording || asr.isTranscribing)
            if asrBackend == "remote" { remoteServerSettings }
        }
    }

    private var remoteServerSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Server URL", text: $voiceServerURL)
                .textFieldStyle(.roundedBorder)
                .help(Text(verbatim: "HTTPS URL from Tailscale Serve, for example https://m1.tailnet.ts.net"))
            SecureField("Server token", text: $voiceServerToken)
                .textFieldStyle(.roundedBorder)
            if let voiceServerTokenError {
                Text(voiceServerTokenError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack(spacing: 8) {
                Button { Task { await asr.checkVoiceServer() } } label: {
                    Label("Test Server", systemImage: "network")
                }
                .disabled(asr.isRecording || asr.isTranscribing || asr.voiceServerConnectionState == .checking)
                Text("HTTPS is required. Audio is sent as WAV bytes; source media stays local for retry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var globalPasteSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Global Right Command paste", isOn: $globalVoicePasteEnabled)
                .toggleStyle(.switch)
                .help(Text(verbatim: "Hold Right Command to record, release to paste the selected Voice mode into the active app."))
            Text(globalVoice.status)
                .font(.caption)
                .foregroundStyle(globalVoice.needsAccessibilityPermission ? .orange : .secondary)
            if globalVoice.needsAccessibilityPermission {
                Button {
                    globalVoice.openAccessibilitySettings()
                } label: {
                    Label("Open Accessibility Settings", systemImage: "lock.shield")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}
