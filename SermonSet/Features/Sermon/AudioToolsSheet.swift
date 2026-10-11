import SermonSetCore
import SwiftUI

/// Voice Focus and trimming. Both make separate copies or windows; the original is never touched.
struct AudioToolsSheet: View {
    @Environment(\.look) private var look
    @Environment(\.dismiss) private var dismiss
    @Environment(SermonStore.self) private var store
    @Environment(PlaybackController.self) private var playback
    let sermon: Sermon

    @State private var voiceFocus: VoiceFocusController?
    @State private var strength = 50.0
    @State private var leaveMusic = true
    @State private var listening: Track = .original

    enum Track: String, CaseIterable, Identifiable {
        case original, enhanced
        var id: String { rawValue }
        var label: String { self == .original ? "Original" : "Voice Focus" }
    }

    private var assets: [AudioAsset] { store.audioAssets(for: sermon.id) }
    private var source: AudioAsset? { assets.first { $0.kind != .enhanced } }
    private var enhanced: AudioAsset? { assets.last { $0.kind == .enhanced } }

    var body: some View {
        NavigationStack {
            ZStack {
                LookBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        voiceFocusSection
                        if let source {
                            TrimSection(sermon: sermon, source: source)
                        }
                        Text("Your original recording is never changed. Voice Focus makes a separate copy, and trimming only sets where playback and sharing start and end.")
                            .font(look.type.caption)
                            .foregroundStyle(look.palette.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(20)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Audio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .storeErrorAlert()
        }
        .onAppear {
            if voiceFocus == nil { voiceFocus = VoiceFocusController(store: store) }
            if let provenance = enhanced.flatMap({ store.derivativeProvenance(for: $0.id) }) {
                strength = provenance.strength * 100
                leaveMusic = !provenance.processMusic
            }
            // Reflect what the player will actually use: the remembered choice, which defaults to the Voice Focus copy.
            if playback.nowPlayingSermonID == sermon.id, let kind = playback.activeAssetKind {
                listening = kind == .enhanced ? .enhanced : .original
            } else {
                listening = store.preferredListeningAsset(for: sermon.id)?.kind == .enhanced ? .enhanced : .original
            }
        }
    }

    // MARK: Voice Focus

    private var voiceFocusSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            LookSectionHeader("Voice Focus", detail: "Clearer speech from a pew recording")
            Text("Takes out rumble, brings voices forward, and evens out the level. Strong settings can sound processed, so compare before you keep it.")
                .font(look.type.callout)
                .foregroundStyle(look.palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Strength").font(look.type.headline).foregroundStyle(look.palette.ink)
                    Spacer()
                    Text("\(Int(strength))%").font(look.type.stamp).foregroundStyle(look.palette.inkSecondary)
                }
                Slider(value: $strength, in: 0...100, step: 5) {
                    Text("Strength")
                } minimumValueLabel: {
                    Text("Light").font(look.type.caption)
                } maximumValueLabel: {
                    Text("Strong").font(look.type.caption)
                }
                .tint(look.palette.accent)
                .foregroundStyle(look.palette.inkSecondary)
                .accessibilityValue("\(Int(strength)) percent")
            }

            Toggle(isOn: $leaveMusic) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Leave music untouched").font(look.type.headline).foregroundStyle(look.palette.ink)
                    Text("Worship and choirs aren’t processed as speech.").font(look.type.caption).foregroundStyle(look.palette.inkSecondary)
                }
            }
            .tint(look.palette.accent)

            if let enhanced, store.derivativeProvenance(for: enhanced.id)?.madeAutomatically == true {
                Label("Made for you after recording at \(Int((store.derivativeProvenance(for: enhanced.id)?.strength ?? 0.5) * 100))%. Your original is kept.", systemImage: "sparkles")
                    .font(look.type.caption)
                    .foregroundStyle(look.palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.jobs(for: sermon.id).voiceFocus.isRunning {
                HStack(spacing: 10) {
                    ProgressView().tint(look.palette.accent)
                    Text("Making your Voice Focus copy…").font(look.type.headline).foregroundStyle(look.palette.ink)
                }
            } else if source != nil {
                VoiceFocusPreviewCard(sermon: sermon, strength: strength, leaveMusic: leaveMusic, hasCopy: enhanced != nil)
            }

            renderControl

            if let enhanced {
                compare(enhanced)
                if let diagnostics = store.derivativeProvenance(for: enhanced.id)?.diagnostics ?? voiceFocus?.diagnostics {
                    DiagnosticsView(diagnostics: diagnostics)
                }
            }
        }
        .lookPanel(padding: 18)
    }

    @ViewBuilder
    private var renderControl: some View {
        switch voiceFocus?.state ?? .idle {
        case .running(let progress):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    ProgressView().tint(look.palette.accent)
                    Text("Making a Voice Focus copy…").font(look.type.headline).foregroundStyle(look.palette.ink)
                }
                if let progress { ProgressTrack(value: progress) }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle").font(look.type.callout).foregroundStyle(look.palette.record)
                renderButton
            }
        case .unavailable(let reason):
            Label(reason, systemImage: "info.circle").font(look.type.callout).foregroundStyle(look.palette.inkSecondary)
        case .idle, .done:
            if settingsChanged { renderButton }
        }
    }

    /// The copy matches the current settings, so there's nothing to remake until something changes.
    private var settingsChanged: Bool {
        guard let enhanced, let provenance = store.derivativeProvenance(for: enhanced.id) else { return true }
        return Int(provenance.strength * 100) != Int(strength) || provenance.processMusic == leaveMusic
    }

    private var renderButton: some View {
        Button {
            Task {
                await voiceFocus?.render(sermonID: sermon.id, strength: strength / 100, processMusic: !leaveMusic)
                if let enhanced { select(.enhanced, asset: enhanced) }
            }
        } label: {
            Label(enhanced == nil ? "Make a Voice Focus copy" : "Make it again at \(Int(strength))%", systemImage: "waveform.badge.magnifyingglass")
        }
        .buttonStyle(.look(enhanced == nil ? .primary : .secondary))
        .disabled(source == nil)
    }

    private func compare(_ enhanced: AudioAsset) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Compare").font(look.type.headline).foregroundStyle(look.palette.ink)
            Picker("Listen to", selection: Binding(get: { listening }, set: { select($0, asset: enhanced) })) {
                ForEach(Track.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack(spacing: 12) {
                Button {
                    if playback.nowPlayingSermonID == sermon.id { playback.toggle() } else { select(listening, asset: enhanced); playback.play() }
                } label: {
                    Image(systemName: playback.nowPlayingSermonID == sermon.id && playback.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(LookIconButtonStyle(size: 46, prominent: true))
                .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                Text("Switching keeps your place and matches loudness, so you hear only the difference.")
                    .font(look.type.caption)
                    .foregroundStyle(look.palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if listening == .enhanced {
                Button("Go back to the original") { select(.original, asset: enhanced) }
                    .buttonStyle(.look(.quiet))
            }
        }
    }

    private func select(_ track: Track, asset enhanced: AudioAsset) {
        if playback.nowPlayingSermonID != sermon.id { playback.load(sermonID: sermon.id, autoplay: false) }
        do {
            if track == .enhanced { try playback.selectAudioAsset(enhanced.id, levelMatched: true) } else { try playback.revertToOriginal() }
            listening = track
        } catch {
            listening = .original
        }
    }
}

private struct DiagnosticsView: View {
    @Environment(\.look) private var look
    var diagnostics: VoiceFocusDiagnostics

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What changed").font(look.type.headline).foregroundStyle(look.palette.ink)
            row("Level", diagnostics.outputLUFS.map { String(format: "%.0f LUFS", $0) } ?? "Mostly silence")
            row("Gain", String(format: "%+.1f dB", diagnostics.appliedGainDB))
            row("Clipping", diagnostics.clippingPercent < 0.05 ? "None" : String(format: "%.1f%% of the recording", diagnostics.clippingPercent))
            if diagnostics.dropoutSeconds > 0.5 {
                row("Dropouts", String(format: "%.0f s of silence gaps", diagnostics.dropoutSeconds))
            }
            if !diagnostics.musicSections.isEmpty {
                row("Music", diagnostics.musicSections.prefix(3).map { "\(Format.clock($0.start))–\(Format.clock($0.end))" }.joined(separator: ", ")
                    + (diagnostics.musicSections.count > 3 ? " and more" : ""))
            }
            Text("Music detection is a best guess. Listen through those parts.")
                .font(look.type.caption)
                .foregroundStyle(look.palette.inkTertiary)
        }
        .padding(.top, 4)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(look.type.callout).foregroundStyle(look.palette.inkSecondary)
            Spacer()
            Text(value).font(look.type.callout.monospacedDigit()).foregroundStyle(look.palette.ink).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Trim

struct TrimSection: View {
    @Environment(\.look) private var look
    @Environment(SermonStore.self) private var store
    @Environment(PlaybackController.self) private var playback
    let sermon: Sermon
    let source: AudioAsset

    @State private var start: TimeInterval = 0
    @State private var end: TimeInterval = 0
    @State private var saved = false
    @State private var error: String?

    private var duration: TimeInterval { max(source.duration, 1) }
    private var isLoaded: Bool { playback.nowPlayingSermonID == sermon.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LookSectionHeader("Trim", detail: "Where the sermon starts and ends")
            Text("Cut the worship set, announcements, or anything personal before and after. You’ll need a trim before sharing audio.")
                .font(look.type.callout)
                .foregroundStyle(look.palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            TrimRange(start: $start, end: $end, duration: duration, position: isLoaded ? playback.currentTime : nil)
                .frame(height: 56)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Starts").font(look.type.caption).foregroundStyle(look.palette.inkTertiary)
                    Text(Format.clock(start)).font(look.type.numerals(22)).foregroundStyle(look.palette.ink)
                }
                Spacer()
                Text(Format.length(end - start)).font(look.type.caption).foregroundStyle(look.palette.inkSecondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Ends").font(look.type.caption).foregroundStyle(look.palette.inkTertiary)
                    Text(Format.clock(end)).font(look.type.numerals(22)).foregroundStyle(look.palette.ink)
                }
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: 10) {
                Button("Hear the start") { playback.play(sermonID: sermon.id, from: start) }
                    .buttonStyle(.look(.secondary))
                Button("Hear the end") { playback.play(sermonID: sermon.id, from: max(start, end - 8)) }
                    .buttonStyle(.look(.secondary))
            }
            if isLoaded {
                HStack(spacing: 10) {
                    Button("Start here") { start = min(playback.currentTime, end - 5); saved = false }
                    Button("End here") { end = max(playback.currentTime, start + 5); saved = false }
                }
                .buttonStyle(.look(.quiet))
            }

            if let error {
                Text(error).font(look.type.caption).foregroundStyle(look.palette.record)
            }
            HStack {
                Button(saved ? "Trim saved" : "Save trim") { save() }
                    .buttonStyle(.look(.primary))
                    .disabled(saved)
                if start > 0 || end < duration {
                    Button("Reset") { start = 0; end = duration; saved = false }.buttonStyle(.look(.quiet))
                }
            }
        }
        .lookPanel(padding: 18)
        .onAppear {
            let window = store.trimWindow(for: source.id)
            start = window?.start ?? 0
            end = window?.end ?? duration
            saved = window != nil
        }
        .onChange(of: start) { saved = false }
        .onChange(of: end) { saved = false }
    }

    private func save() {
        do {
            try store.setTrimWindow(AudioTrimWindow(start: start, end: end), for: source.id)
            error = nil
            saved = true
        } catch {
            self.error = (error as? SermonSetError)?.message ?? "That trim isn’t valid. Keep at least a few seconds."
        }
    }
}

/// Two handles on a track. Each handle is adjustable with VoiceOver in 5-second steps.
struct TrimRange: View {
    @Environment(\.look) private var look
    @Binding var start: TimeInterval
    @Binding var end: TimeInterval
    var duration: TimeInterval
    var position: TimeInterval?
    private let minGap: TimeInterval = 5

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let x = { (t: TimeInterval) in CGFloat(t / duration) * width }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: look.shape.smallRadius)
                    .fill(look.palette.rule.opacity(look.id == .rubric ? 1 : 0.5))
                    .frame(height: 14)
                    .frame(maxHeight: .infinity)
                RoundedRectangle(cornerRadius: look.shape.smallRadius)
                    .fill(look.palette.accent.opacity(0.85))
                    .frame(width: max(0, x(end) - x(start)), height: 14)
                    .offset(x: x(start))
                    .frame(maxHeight: .infinity)
                if let position {
                    Rectangle().fill(look.palette.ink).frame(width: 2, height: 30)
                        .offset(x: x(min(max(position, 0), duration)) - 1)
                        .frame(maxHeight: .infinity)
                        .accessibilityHidden(true)
                }
                handle(label: "Start", value: start)
                    .offset(x: x(start) - 14)
                    .gesture(DragGesture().onChanged { g in
                        start = min(max(0, Double(g.location.x / width) * duration), end - minGap)
                    })
                    .accessibilityAdjustableAction { dir in
                        start = dir == .increment ? min(start + 5, end - minGap) : max(0, start - 5)
                    }
                handle(label: "End", value: end)
                    .offset(x: x(end) - 14)
                    .gesture(DragGesture().onChanged { g in
                        end = max(min(duration, Double(g.location.x / width) * duration), start + minGap)
                    })
                    .accessibilityAdjustableAction { dir in
                        end = dir == .increment ? min(duration, end + 5) : max(start + minGap, end - 5)
                    }
            }
        }
    }

    private func handle(label: String, value: TimeInterval) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(look.palette.record)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(look.palette.ink.opacity(look.id == .riso ? 1 : 0.2), lineWidth: look.id == .riso ? 2 : 1))
            .frame(width: 28, height: 44)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle().inset(by: -12))
            .accessibilityElement()
            .accessibilityLabel("\(label) of sermon")
            .accessibilityValue(Format.spokenClock(value))
    }
}
