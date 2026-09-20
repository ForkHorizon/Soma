import SwiftUI

extension Layer2PreferredReviewView {
    func player(_ file: Layer1AudioFile) -> some View {
        let url = file.url
        let active = asr.playingURL == url
        let duration = active ? asr.playbackDuration : file.duration
        return VStack(spacing: 7) {
            HStack(spacing: 8) {
                Button {
                    if active { asr.rewindPlayback() }
                } label: {
                    Label("−5 s", systemImage: "gobackward.5")
                }
                .disabled(!active)
                Button {
                    active ? asr.pauseOrResumePlayback() : asr.togglePlayback(url)
                } label: {
                    Label(
                        active && !asr.isPlaybackPaused ? "Pause" : "Play",
                        systemImage: active && !asr.isPlaybackPaused ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Text("\(formatTime(asr.playbackTime)) / \(formatTime(duration))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { active ? asr.playbackTime : 0 },
                    set: { asr.seekPlayback(to: $0) }),
                in: 0...max(duration, 0.1)
            )
            .disabled(!active)
            if let playbackError = asr.playbackError {
                Text(playbackError).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
