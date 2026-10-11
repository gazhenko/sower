import AVFoundation
import SermonSetCore
import SwiftUI

/// Hear Voice Focus on 20 seconds of this recording before making the whole copy. Flipping sides keeps your place,
/// and both sides are loudness-matched so you hear the change in tone, not volume.
struct VoiceFocusPreviewCard: View {
    @Environment(\.look) private var look
    @Environment(SermonStore.self) private var store
    @Environment(PlaybackController.self) private var playback
    let sermon: Sermon
    let strength: Double
    let leaveMusic: Bool
    var hasCopy = false

    @State private var player = ABPreviewPlayer()
    @State private var preview: VoiceFocusPreview?
    @State private var working = false
    @State private var error: String?
    @State private var stale = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(hasCopy ? "Try a different strength first" : "Hear it first").font(look.type.headline).foregroundStyle(look.palette.ink)
            if let preview {
                Picker("Listen to", selection: Binding(get: { player.side }, set: { player.switchTo($0) })) {
                    Text("Original").tag(ABPreviewPlayer.Side.original)
                    Text("Voice Focus").tag(ABPreviewPlayer.Side.focused)
                }
                .pickerStyle(.segmented)
                HStack(spacing: 12) {
                    Button {
                        if player.isPlaying { player.pause() } else { playback.pause(); player.play() }
                    } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill") }
                    .buttonStyle(LookIconButtonStyle(size: 46, prominent: true))
                    .accessibilityLabel(player.isPlaying ? "Pause preview" : "Play preview")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Format.clock(preview.start + player.currentTime)) · \(Int(preview.duration)) seconds at \(Int(strength))%")
                            .font(look.type.stamp)
                            .foregroundStyle(look.palette.inkSecondary)
                        Text(working ? "Updating the preview…" : "Flip between them while it plays.")
                            .font(look.type.caption)
                            .foregroundStyle(look.palette.inkTertiary)
                    }
                }
            } else {
                Text("Listen to 20 seconds with Voice Focus before making the whole copy\(playback.nowPlayingSermonID == sermon.id ? ", starting where you are" : "").")
                    .font(look.type.caption)
                    .foregroundStyle(look.palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { Task { await make(keepingPlace: false) } } label: {
                    if working { ProgressView() } else { Label("Preview 20 seconds", systemImage: "headphones") }
                }
                .buttonStyle(.look(.secondary))
                .disabled(working)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(look.type.caption).foregroundStyle(look.palette.record)
            }
        }
        // Moving the slider or the music switch re-renders the same excerpt, keeping your side and place.
        .task(id: "\(strength)-\(leaveMusic)") {
            guard preview != nil else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await make(keepingPlace: true)
        }
        .onDisappear { player.stop() }
    }

    private func make(keepingPlace: Bool) async {
        working = true; error = nil
        defer { working = false }
        let around: TimeInterval? = preview?.start ?? (playback.nowPlayingSermonID == sermon.id ? playback.currentTime : nil)
        do {
            let next = try await store.previewVoiceFocus(sermonID: sermon.id, strength: strength / 100, processMusic: !leaveMusic, around: around)
            let resume = keepingPlace && player.isPlaying
            try player.load(next, keepingPlace: keepingPlace)
            preview = next
            if !keepingPlace { playback.pause(); player.play() } else if resume { player.play() }
        } catch is CancellationError {
        } catch {
            self.error = (error as? SermonSetError)?.message ?? error.localizedDescription
        }
    }
}

/// Two loudness-matched clips that play in lockstep; switching sides keeps the position.
@MainActor @Observable final class ABPreviewPlayer {
    enum Side: Hashable { case original, focused }
    private(set) var side: Side = .focused
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private var players: [Side: AVAudioPlayer] = [:]
    private var ticker: Task<Void, Never>?

    func load(_ preview: VoiceFocusPreview, keepingPlace: Bool) throws {
        let place = keepingPlace ? currentTime : 0
        let wasPlaying = isPlaying
        stop()
        let original = try AVAudioPlayer(contentsOf: preview.original), focused = try AVAudioPlayer(contentsOf: preview.focused)
        [original, focused].forEach { $0.numberOfLoops = -1; $0.prepareToPlay(); $0.currentTime = place }
        players = [.original: original, .focused: focused]
        currentTime = place
        if wasPlaying { play() }
    }

    func play() {
        guard let active = players[side] else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        active.currentTime = currentTime
        active.play()
        isPlaying = true
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let p = self.players[self.side] else { return }
                self.currentTime = p.currentTime
            }
        }
    }

    func pause() {
        players.values.forEach { $0.pause() }
        isPlaying = false
        ticker?.cancel()
    }

    func switchTo(_ next: Side) {
        guard next != side else { return }
        let place = players[side]?.currentTime ?? currentTime
        let resume = isPlaying
        players[side]?.pause()
        side = next
        currentTime = place
        players[next]?.currentTime = place
        if resume { players[next]?.play() }
    }

    func stop() {
        players.values.forEach { $0.stop() }
        isPlaying = false
        ticker?.cancel()
    }
}
