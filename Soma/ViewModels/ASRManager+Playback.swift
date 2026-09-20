import AVFoundation
import Foundation

extension ASRManager {
    func togglePlayback(_ url: URL) {
        togglePlayback(url, from: nil, to: nil)
    }

    func togglePlayback(_ url: URL, from start: Double?, to end: Double?) {
        if playingURL == url || playbackPendingURL == url {
            stopPlayback()
            return
        }
        stopPlayback()
        playbackPendingURL = url
        let requestID = playbackRequestID
        playbackLoadTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }
            guard FileManager.default.fileExists(atPath: url.path) else {
                await self?.finishPlaybackRequest(
                    requestID, error: "Audio file is missing: \(url.lastPathComponent)")
                return
            }
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                guard !Task.isCancelled else {
                    player.stop()
                    return
                }
                await MainActor.run { [weak self, player] in
                    guard let self, self.playbackRequestID == requestID else {
                        player.stop()
                        return
                    }
                    self.startPlayback(player, url: url, start: start, end: end)
                }
            } catch {
                await self?.finishPlaybackRequest(requestID, error: error.localizedDescription)
            }
        }
    }

    func pauseOrResumePlayback() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaybackPaused = true
        } else if player.currentTime < (playbackEnd ?? player.duration) {
            if player.play() {
                isPlaybackPaused = false
            } else {
                playbackError = "Audio playback could not be resumed."
            }
        }
    }

    func rewindPlayback(by seconds: TimeInterval = 5) {
        guard let player else { return }
        player.currentTime = max(0, player.currentTime - max(seconds, 0))
        playbackTime = player.currentTime
    }

    func seekPlayback(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(time, 0), player.duration)
        playbackTime = player.currentTime
    }

    private func startPlaybackMonitor() {
        playbackMonitor?.invalidate()
        playbackMonitor = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let player = self.player else { return }
            self.playbackTime = player.currentTime
            if player.currentTime >= (self.playbackEnd ?? player.duration) - 0.05 {
                self.stopPlayback()
            }
        }
    }

    func stopPlayback() {
        playbackLoadTask?.cancel()
        playbackLoadTask = nil
        playbackRequestID = UUID()
        playbackMonitor?.invalidate()
        playbackMonitor = nil
        player?.stop()
        player = nil
        playingURL = nil
        playbackEnd = nil
        playbackTime = 0
        playbackDuration = 0
        isPlaybackPaused = false
        playbackError = nil
        playbackPendingURL = nil
    }

    private func startPlayback(
        _ newPlayer: AVAudioPlayer, url: URL, start: Double?, end: Double?
    ) {
        playbackLoadTask = nil
        playbackPendingURL = nil
        player = newPlayer
        let begin = min(max(start ?? 0, 0), max(newPlayer.duration - 0.05, 0))
        let finish = min(max(end ?? newPlayer.duration, begin), newPlayer.duration)
        newPlayer.currentTime = begin
        guard newPlayer.play() else {
            playbackError = "Audio playback could not be started."
            player = nil
            return
        }
        playingURL = url
        playbackTime = begin
        playbackDuration = newPlayer.duration
        playbackEnd = finish
        isPlaybackPaused = false
        startPlaybackMonitor()
    }

    private func finishPlaybackRequest(_ requestID: UUID, error: String) async {
        await MainActor.run { [weak self] in
            guard let self, self.playbackRequestID == requestID else { return }
            self.playbackLoadTask = nil
            self.playbackPendingURL = nil
            self.playbackError = error
            self.status = "Playback error: \(error)"
        }
    }
}
