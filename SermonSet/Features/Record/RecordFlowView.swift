import SermonSetCore
import SwiftUI

/// Capture, built for a pew: one big control, one big Mark button, nothing to fiddle with.
struct RecordFlowView: View {
    @Environment(\.look) private var look
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SermonStore.self) private var store
    @Environment(CaptureController.self) private var capture
    @Environment(AppRouter.self) private var router

    @State private var saved: Sermon?
    @State private var consent = false
    @State private var showDetails = false
    @State private var title = ""
    @State private var preacher = ""
    @State private var church = ""
    @State private var city = ""
    @State private var startError: String?
    @State private var isStarting = false
    @State private var dimmed = false
    @State private var service: VerifiedService?

    var body: some View {
        ZStack {
            LookBackground()
            if let saved {
                SavedView(sermon: saved) {
                    dismiss()
                    router.openSermon(saved.id)
                } onDone: {
                    dismiss()
                }
            } else if capture.isActive {
                LiveRecordingView(dimmed: $dimmed, onSaved: { sermon in
                    withAnimation { saved = sermon }
                    // Notes and the automatic Voice Focus copy run together; Voice Focus alone if notes are off.
                    if store.summarizeAfterRecording {
                        Task { await store.processRecording(sermonID: sermon.id) }
                    } else if store.voiceFocusAfterRecording {
                        Task { await store.processVoiceFocusAfterRecording(sermonID: sermon.id) }
                    }
                })
            } else {
                setup
            }
            if dimmed && capture.isActive {
                Color.black.opacity(0.62).ignoresSafeArea().allowsHitTesting(false)
            }
        }
        .animation(.snappy, value: capture.isActive)
        .onChange(of: scenePhase) { _, phase in
            // Returning from Settings: pick up a microphone permission the listener just turned on.
            if phase == .active, capture.micPermission == .denied {
                Task { _ = await capture.requestPermission() }
            }
        }
        .storeErrorAlert()
        .onChange(of: service) { _, service in
            guard let grant = service?.grant else { return }
            consent = grant.recordingAllowed
            if let name = service?.churchName, church.isEmpty { church = name }
        }
    }

    private var recordingDeclined: Bool { service?.grant.recordingAllowed == false }

    // MARK: Setup

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .buttonStyle(LookIconButtonStyle(size: 40))
                        .accessibilityLabel("Close")
                    Spacer()
                    PrivateBadge()
                }

                Text("Record a sermon")
                    .font(look.type.hero)
                    .lookDisplay(look)
                    .foregroundStyle(look.palette.ink)

                Text("The recording stays on this iPhone. Nothing is uploaded, and you don’t need an account.")
                    .font(look.type.body)
                    .foregroundStyle(look.palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                ServiceQRCard(verified: $service)

                consentCard

                DisclosureGroup(isExpanded: $showDetails) {
                    VStack(alignment: .leading, spacing: 10) {
                        VenueSuggestions { candidate in
                            church = candidate.churchName
                            city = candidate.city ?? city
                        }
                        LookTextField(placeholder: "Title", text: $title)
                        LookTextField(placeholder: "Preacher", text: $preacher)
                        LookTextField(placeholder: "Church", text: $church)
                        LookTextField(placeholder: "City", text: $city)
                    }
                    .padding(.top, 10)
                } label: {
                    Text("Add details now (optional)")
                        .font(look.type.headline)
                        .foregroundStyle(look.palette.ink)
                }
                .tint(look.palette.ink)

                if capture.micPermission == .denied {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Microphone access is off", systemImage: "mic.slash")
                            .font(look.type.headline)
                            .foregroundStyle(look.palette.ink)
                        Text("Turn on the microphone for \(AppBrand.name) in Settings to record.")
                            .font(look.type.callout)
                            .foregroundStyle(look.palette.inkSecondary)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                        .buttonStyle(.look(.secondary))
                    }
                    .lookPanel(padding: 14)
                }

                if let startError {
                    Text(startError).font(look.type.callout).foregroundStyle(look.palette.record)
                }

                VStack(spacing: 12) {
                    RecordButton(isRecording: false, isBusy: isStarting) { Task { await start() } }
                        .disabled(!consent || isStarting)
                        .opacity(consent ? 1 : 0.45)
                    Text(recordingDeclined ? "This church’s service code asks for no recording" : consent ? "Tap to start recording" : "Confirm recording is welcome to start")
                        .font(look.type.callout)
                        .foregroundStyle(look.palette.inkSecondary)
                    if capture.estimatedTimeRemaining > 0 {
                        Text(Format.hoursRemaining(capture.estimatedTimeRemaining))
                            .font(look.type.caption)
                            .foregroundStyle(look.palette.inkTertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
    }

    private var consentCard: some View {
        Button { consent.toggle() } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: consent ? "checkmark.square.fill" : "square")
                    .font(.title2)
                    .foregroundStyle(consent ? look.palette.accent : look.palette.inkSecondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recording is welcome at this service")
                        .font(look.type.headline)
                        .foregroundStyle(look.palette.ink)
                    Text("Ask if you’re not sure. Recording for yourself is different from sharing, and \(AppBrand.name) never shares a recording on its own.")
                        .font(look.type.caption)
                        .foregroundStyle(look.palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .disabled(recordingDeclined)
        .opacity(recordingDeclined ? 0.5 : 1)
        .lookPanel(padding: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording is welcome at this service")
        .accessibilityHint("Confirms you checked. Recording for yourself is different from sharing.")
        .accessibilityAddTraits(consent ? [.isSelected, .isButton] : .isButton)
    }

    private func start() async {
        startError = nil
        isStarting = true
        defer { isStarting = false }
        // A start that failed before any audio was captured leaves nothing worth keeping; clear it.
        if capture.failure != nil, !capture.isActive {
            await capture.discard()
        }
        if capture.micPermission != .granted {
            guard await capture.requestPermission() else {
                startError = "Microphone access is off. Turn it on for \(AppBrand.name) in Settings, then try again."
                return
            }
        }
        func clean(_ s: String) -> String? { let t = s.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : t }
        do {
            try await capture.start(CaptureDraft(title: clean(title), preacher: clean(preacher), churchName: clean(church), city: clean(city), serviceToken: service?.token))
        } catch {
            startError = (error as? SermonSetError)?.message ?? error.localizedDescription
        }
    }
}

// MARK: - Live

struct LiveRecordingView: View {
    @Environment(\.look) private var look
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(CaptureController.self) private var capture
    @Binding var dimmed: Bool
    var onSaved: (Sermon) -> Void

    @State private var markFlash = 0
    @State private var lastMarked: TimeInterval?
    @State private var noteDraft = ""
    @State private var isWritingNote = false
    @State private var confirmStop = false
    @State private var confirmDiscard = false
    @State private var stopError: String?
    @FocusState private var noteFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(spacing: 22) {
                    statusLine
                    if let failure = capture.failure {
                        FailedSessionPanel(error: failure, onRetry: { Task { await stop() } }, onDiscard: { confirmDiscard = true })
                    }
                    Text(Format.clock(capture.elapsed))
                        .font(look.type.numerals(look.id == .riso ? 104 : 84))
                        .foregroundStyle(look.palette.ink)
                        .contentTransition(.numericText())
                        .accessibilityLabel(Text("Recorded \(Format.spokenClock(capture.elapsed))"))
                    LevelMeter(level: capture.level, history: capture.levelHistory, active: capture.phase == .recording)
                        .frame(height: 96)
                    markButton
                    noteArea
                    if !capture.sessionMoments.isEmpty || !capture.sessionNotes.isEmpty {
                        sessionLog
                    }
                    if !capture.recoveryEvents.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(capture.recoveryEvents.suffix(3), id: \.self) { event in
                                Label(event, systemImage: "info.circle")
                            }
                        }
                        .font(look.type.caption)
                        .foregroundStyle(look.palette.inkTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)
            controls
        }
        .overlay {
            if capture.phase == .finishing {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large).tint(look.palette.accent)
                    Text("Saving your recording…").font(look.type.headline).foregroundStyle(look.palette.ink)
                }
                .lookPanel(padding: 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.2).ignoresSafeArea())
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: markFlash)
        .confirmationDialog("Stop and save this recording?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop and save") { Task { await stop() } }
            Button("Keep recording", role: .cancel) {}
        } message: {
            Text("It goes straight into your library. You can transcribe it and make a card later.")
        }
        .confirmationDialog("Discard this recording?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard recording", role: .destructive) { Task { await capture.discard() } }
            Button("Keep recording", role: .cancel) {}
        } message: {
            Text("The audio, moments, and notes from this session will be deleted.")
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: { Image(systemName: "chevron.down") }
                .buttonStyle(LookIconButtonStyle(size: 40))
                .accessibilityLabel("Hide recorder")
                .accessibilityHint("Recording continues while you browse.")
            Spacer()
            PrivateBadge()
            Spacer()
            Menu {
                Button(dimmed ? "Brighten screen" : "Dim screen", systemImage: dimmed ? "sun.max" : "moon") { dimmed.toggle() }
                Button("Discard recording", systemImage: "trash", role: .destructive) { confirmDiscard = true }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(look.palette.ink)
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .opacity(capture.phase == .recording && !reduceMotion ? 1 : 0.9)
                .phaseAnimator([1.0, 0.35], trigger: capture.phase == .recording && !reduceMotion) { view, value in
                    view.opacity(capture.phase == .recording && !reduceMotion ? value : 1)
                }
            Text(statusText).font(look.type.headline).foregroundStyle(look.palette.ink)
            if !capture.inputName.isEmpty {
                Text("· \(capture.inputName)").font(look.type.callout).foregroundStyle(look.palette.inkSecondary)
            }
        }
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        switch capture.phase {
        case .preparing: "Getting ready"
        case .recording: "Recording"
        case .paused: "Paused"
        case .interrupted(let reason): "Interrupted: \(reason)"
        case .finishing: "Saving"
        case .failed(let error): error.title
        case .idle: "Ready"
        }
    }

    private var statusColor: Color {
        switch capture.phase {
        case .recording: look.palette.record
        case .interrupted, .failed: look.palette.caution
        default: look.palette.inkTertiary
        }
    }

    private var markButton: some View {
        Button {
            capture.markMoment()
            lastMarked = capture.elapsed
            markFlash += 1
            UIAccessibility.post(notification: .announcement, argument: "Marked")
        } label: {
            VStack(spacing: 4) {
                Label("Mark this moment", systemImage: "bookmark.fill")
                    .font(look.id == .riso ? .custom("Futura-CondensedExtraBold", 28, .title2) : look.id == .sower ? SowerType.display(36, .title2, weight: .light) : look.type.label.weight(.bold))
                    .textCase(look.id == .riso || look.id == .sower ? .uppercase : nil)
                Text(markSubtitle).font(look.type.caption).opacity(0.8)
            }
            .foregroundStyle(look.palette.onMoment)
            .frame(maxWidth: .infinity)
            .frame(height: 96)
            .background(markBackground)
        }
        .buttonStyle(PressScaleStyle())
        .disabled(capture.phase != .recording)
        .opacity(capture.phase == .recording ? 1 : 0.5)
        .accessibilityLabel("Mark this moment")
        .accessibilityValue(markSubtitle)
        .accessibilityHint("Saves this point in the sermon so you can return to it.")
    }

    private var markSubtitle: String {
        if let lastMarked { return "Marked \(Format.clock(lastMarked)) · \(capture.sessionMoments.count) so far" }
        return capture.sessionMoments.isEmpty ? "Tap when something lands" : "\(capture.sessionMoments.count) marked"
    }

    @ViewBuilder
    private var markBackground: some View {
        switch look.id {
        case .sower:
            RoundedRectangle(cornerRadius: 2).fill(look.palette.moment)
        case .riso:
            RoundedRectangle(cornerRadius: 10).fill(look.palette.moment)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(look.palette.ink, lineWidth: 3))
                .background(RoundedRectangle(cornerRadius: 10).fill(look.palette.ink).offset(x: 5, y: 5))
        case .rubric:
            RoundedRectangle(cornerRadius: 2).fill(look.palette.moment)
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(look.palette.onMoment.opacity(0.4), lineWidth: 1).padding(4))
        case .vespers:
            RoundedRectangle(cornerRadius: 28, style: .continuous).fill(look.palette.moment.opacity(0.92))
                .shadow(color: look.palette.moment.opacity(0.35), radius: 18)
        case .lumen:
            RoundedRectangle(cornerRadius: 30, style: .continuous).fill(.clear)
                .glassEffect(.regular.tint(look.palette.moment).interactive(), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        case .midnight:
            RoundedRectangle(cornerRadius: 3).fill(look.palette.moment)
                .overlay(alignment: .topLeading) {
                    Text(verbatim: "F1").font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(look.palette.onMoment.opacity(0.55)).padding(6)
                }
        }
    }

    @ViewBuilder
    private var noteArea: some View {
        if isWritingNote {
            VStack(alignment: .trailing, spacing: 8) {
                LookTextField(placeholder: "Note at \(Format.clock(capture.elapsed))", text: $noteDraft, axis: .vertical)
                    .focused($noteFocused)
                HStack {
                    Button("Cancel") { isWritingNote = false; noteDraft = "" }.buttonStyle(.look(.quiet))
                    Button("Save note") {
                        let text = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { capture.addNote(text) }
                        noteDraft = ""
                        isWritingNote = false
                    }
                    .buttonStyle(.look(.primary))
                }
            }
        } else {
            Button {
                isWritingNote = true
                noteFocused = true
            } label: {
                Label("Write a note", systemImage: "square.and.pencil")
            }
            .buttonStyle(.look(.secondary, fullWidth: true))
        }
    }

    private var sessionLog: some View {
        let items: [(TimeInterval, String?)] =
            capture.sessionMoments.map { ($0.time, $0.note) } + capture.sessionNotes.compactMap { note in note.time.map { ($0, note.text) } }
        return VStack(alignment: .leading, spacing: 0) {
            Text("This session").font(look.type.caption).foregroundStyle(look.palette.inkTertiary).padding(.bottom, 4)
            ForEach(Array(items.sorted { $0.0 > $1.0 }.prefix(4).enumerated()), id: \.offset) { _, item in
                MomentRow(time: item.0, text: item.1, placeholder: "Marked", showsPlay: false)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button {
                if capture.phase == .recording { capture.pause() } else { try? capture.resume() }
            } label: {
                Label(capture.phase == .recording ? "Pause" : "Resume", systemImage: capture.phase == .recording ? "pause.fill" : "record.circle")
            }
            .buttonStyle(.look(.secondary, fullWidth: true))
            .disabled(capture.phase == .finishing || capture.phase == .preparing || capture.failure != nil)

            Button { confirmStop = true } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.look(.destructive, fullWidth: true))
            .disabled(capture.phase == .finishing || capture.phase == .preparing)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .overlay(alignment: .top) {
            if let stopError {
                Text(stopError).font(look.type.caption).foregroundStyle(look.palette.record).offset(y: -18)
            }
        }
    }

    private func stop() async {
        do {
            let sermon = try await capture.stop()
            onSaved(sermon)
        } catch {
            stopError = (error as? SermonSetError)?.message ?? error.localizedDescription
        }
    }
}

/// Shown when saving a session failed but its audio is still on disk.
struct FailedSessionPanel: View {
    @Environment(\.look) private var look
    var error: SermonSetError
    var onRetry: () -> Void
    var onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(error.title, systemImage: "exclamationmark.triangle")
                .font(look.type.headline)
                .foregroundStyle(look.palette.ink)
            Text([error.message, error.recoverySuggestion].compactMap { $0 }.joined(separator: " "))
                .font(look.type.callout)
                .foregroundStyle(look.palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("The audio recorded so far is still on this iPhone.")
                .font(look.type.caption)
                .foregroundStyle(look.palette.inkTertiary)
            HStack(spacing: 12) {
                Button("Try saving again", action: onRetry).buttonStyle(.look(.primary))
                Button("Discard", role: .destructive, action: onDiscard).buttonStyle(.look(.quiet))
            }
        }
        .lookPanel(padding: 16)
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Saved

struct SavedView: View {
    @Environment(\.look) private var look
    @Environment(SermonStore.self) private var store
    var sermon: Sermon
    var onOpen: () -> Void
    var onDone: () -> Void

    /// The pipeline ended without a summary (failed, unavailable, or no speech): say so on the sermon page.
    private var summaryStopped: Bool {
        let jobs = store.jobs(for: sermon.id)
        let running = jobs.transcription.isRunning || jobs.insights.isRunning || jobs.summary.isRunning
        let started = jobs.transcription != .idle || jobs.insights != .idle || jobs.summary != .idle
        return started && !running
    }

    var body: some View {
        let duration = store.audioAssets(for: sermon.id).first?.duration ?? 0
        let moments = store.moments(for: sermon.id).count
        VStack(alignment: .leading, spacing: 20) {
            Spacer(minLength: 12)
            Image(systemName: "checkmark.circle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(look.palette.positive)
            Text("Saved to your library")
                .font(look.type.hero)
                .lookDisplay(look)
                .foregroundStyle(look.palette.ink)
            VStack(alignment: .leading, spacing: 6) {
                Text(Format.title(sermon)).font(look.type.headline).foregroundStyle(look.palette.ink)
                Text("\(Format.length(duration)) · \(moments == 1 ? "1 moment" : "\(moments) moments") marked")
                    .font(look.type.callout)
                    .foregroundStyle(look.palette.inkSecondary)
                PrivateBadge().padding(.top, 4)
            }
            if let notes = store.insights(for: sermon.id)?.notes {
                VStack(alignment: .leading, spacing: 14) {
                    BigIdea(text: notes.bigIdea)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(notes.points.enumerated()), id: \.element.id) { index, point in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                PointMarker(index: index + 1).scaleEffect(0.7, anchor: .leading).frame(width: 30, alignment: .leading)
                                Text(point.heading).font(look.type.headline).foregroundStyle(look.palette.ink)
                            }
                        }
                    }
                }
                .padding(.top, 4)
                .transition(.opacity)
            } else if store.summarizeAfterRecording, !summaryStopped {
                NotesProgress(sermonID: sermon.id)
            } else {
                Text("Listen back whenever you like. You can get sermon notes on the sermon page whenever you’re ready.")
                    .font(look.type.body)
                    .foregroundStyle(look.palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VStack(spacing: 12) {
                Button(store.insights(for: sermon.id)?.notes == nil ? "Open sermon" : "Read the notes", action: onOpen)
                    .buttonStyle(.look(.primary, fullWidth: true))
                Button("Done", action: onDone).buttonStyle(.look(.secondary, fullWidth: true))
            }
        }
        .padding(24)
    }
}

// MARK: - Controls

/// The single large record control, drawn per look.
struct RecordButton: View {
    @Environment(\.look) private var look
    var isRecording: Bool
    var isBusy = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                switch look.id {
                case .sower:
                    Circle().strokeBorder(look.palette.accent, lineWidth: 1)
                    Circle().fill(look.palette.accent).padding(10)
                    Text(verbatim: "REC").font(SowerType.display(48, .title)).foregroundStyle(look.palette.onAccent)
                case .riso:
                    Circle().fill(look.palette.ink).offset(x: 6, y: 6)
                    Circle().fill(look.palette.record)
                    HalftoneDisc(color: look.palette.ink.opacity(0.18), spacing: 7).padding(18).clipShape(Circle())
                    Circle().strokeBorder(look.palette.ink, lineWidth: 3)
                    Text("REC").font(.custom("Futura-CondensedExtraBold", 40, .title)).foregroundStyle(look.palette.ink)
                case .rubric:
                    Circle().strokeBorder(look.palette.accent, lineWidth: 1)
                    Circle().strokeBorder(look.palette.accent.opacity(0.5), lineWidth: 0.5).padding(6)
                    Circle().fill(look.palette.accent).padding(14)
                    Image(systemName: "mic.fill").font(.system(size: 34, weight: .regular)).foregroundStyle(look.palette.onAccent)
                case .vespers:
                    Circle().fill(look.palette.record.opacity(0.12)).scaleEffect(1.18).blur(radius: 10)
                    Circle().strokeBorder(look.palette.record, lineWidth: 2)
                    Circle().fill(look.palette.record).padding(34)
                case .lumen:
                    Circle().fill(.clear)
                        .glassEffect(.regular.tint(look.palette.record).interactive(), in: Circle())
                    Image(systemName: "mic.fill").font(.system(size: 38, weight: .semibold)).foregroundStyle(.white)
                case .midnight:
                    // A terminal key: a coral cap inside a hairline frame.
                    RoundedRectangle(cornerRadius: 4).strokeBorder(look.palette.record.opacity(0.6), lineWidth: 1)
                    RoundedRectangle(cornerRadius: 3).fill(look.palette.record).padding(10)
                    VStack(spacing: 2) {
                        Text(verbatim: isRecording ? "■" : "●").font(.system(size: 22, weight: .bold, design: .monospaced))
                        Text(verbatim: isRecording ? "stop" : "rec").font(.system(size: 30, weight: .bold, design: .monospaced))
                    }
                    .foregroundStyle(look.palette.onRecord)
                }
                if isBusy { ProgressView().tint(look.palette.ink) }
            }
            .frame(width: 140, height: 140)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }
}

/// Live input level, drawn per look. The meter is information, so it stays visible under
/// Reduce Motion but never pulses on its own.
struct LevelMeter: View {
    @Environment(\.look) private var look
    var level: Float
    var history: [Float]
    var active: Bool

    var body: some View {
        GeometryReader { proxy in
            let values = padded(count: barCount(for: proxy.size.width))
            switch look.id {
            case .sower: sower(values, size: proxy.size)
            case .riso: riso(values, size: proxy.size)
            case .rubric: rubric(values, size: proxy.size)
            case .vespers: vespers(size: proxy.size)
            case .lumen: lumen(values, size: proxy.size)
            case .midnight: midnight(values, size: proxy.size)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue(level < 0.05 ? "Quiet" : (level < 0.4 ? "Speech" : "Loud"))
    }

    private func barCount(for width: CGFloat) -> Int { max(16, Int(width / 9)) }

    private func padded(count: Int) -> [CGFloat] {
        let recent = history.suffix(count).map { CGFloat($0) }
        return Array(repeating: 0, count: max(0, count - recent.count)) + recent
    }

    /// A sparkline in block characters: each column snaps to one of eight heights, ▁ to █.
    private func midnight(_ values: [CGFloat], size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let step = canvasSize.width / CGFloat(values.count)
            let unit = canvasSize.height * 0.8 / 8
            let base = canvasSize.height * 0.9
            context.fill(Path(CGRect(x: 0, y: base, width: canvasSize.width, height: 1)), with: .color(look.palette.rule))
            for (i, value) in values.enumerated() {
                let level = max(1, min(8, Int((value * 8).rounded(.up))))
                let rect = CGRect(x: CGFloat(i) * step + 1, y: base - CGFloat(level) * unit, width: max(1, step - 2), height: CGFloat(level) * unit)
                let color = i == values.count - 1 ? look.palette.accent : look.palette.accent.opacity(0.5)
                context.fill(Path(rect), with: .color(color))
            }
        }
    }

    /// Columns of printed squares, like the website's dithered plates.
    private func sower(_ values: [CGFloat], size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let step = canvasSize.width / CGFloat(values.count)
            let square: CGFloat = 4
            var path = Path()
            for (i, value) in values.enumerated() {
                let rows = Int(max(1, value * 9))
                let x = CGFloat(i) * step + (step - square) / 2
                for r in 0..<rows {
                    let offset = CGFloat(r) * (square + 2)
                    path.addRect(CGRect(x: x, y: canvasSize.height / 2 - offset - square, width: square, height: square))
                    path.addRect(CGRect(x: x, y: canvasSize.height / 2 + offset, width: square, height: square))
                }
            }
            context.fill(path, with: .color(look.palette.ink))
        }
    }

    private func riso(_ values: [CGFloat], size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let step = canvasSize.width / CGFloat(values.count)
            let dot: CGFloat = 5
            for (i, value) in values.enumerated() {
                let rows = Int(max(1, value * 12))
                let x = CGFloat(i) * step + step / 2
                for r in 0..<rows {
                    let offset = CGFloat(r) * (dot + 2)
                    let color: Color = i == values.count - 1 ? look.palette.record : look.palette.ink
                    for y in [canvasSize.height / 2 - offset, canvasSize.height / 2 + offset] {
                        context.fill(Path(ellipseIn: CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)), with: .color(color))
                    }
                }
            }
        }
    }

    private func rubric(_ values: [CGFloat], size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let mid = canvasSize.height / 2
            var line = Path()
            line.move(to: CGPoint(x: 0, y: mid))
            line.addLine(to: CGPoint(x: canvasSize.width, y: mid))
            context.stroke(line, with: .color(look.palette.rule), lineWidth: 1)
            var wave = Path()
            let step = canvasSize.width / CGFloat(max(values.count - 1, 1))
            for (i, value) in values.enumerated() {
                let x = CGFloat(i) * step
                let amplitude = value * canvasSize.height * 0.45
                let y = mid + (i.isMultiple(of: 2) ? -amplitude : amplitude)
                if i == 0 { wave.move(to: CGPoint(x: x, y: y)) } else { wave.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(wave, with: .color(look.palette.accent), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
        }
    }

    private func vespers(size: CGSize) -> some View {
        let glow = CGFloat(active ? max(0.15, level) : 0.08)
        return ZStack {
            Circle()
                .fill(RadialGradient(colors: [look.palette.accent.opacity(0.55), .clear], center: .center, startRadius: 2, endRadius: 46 + 40 * glow))
                .frame(width: 96 + 80 * glow, height: 96 + 80 * glow)
            Circle()
                .fill(look.palette.accent)
                .frame(width: 10 + 10 * glow, height: 10 + 10 * glow)
                .shadow(color: look.palette.accent, radius: 10)
        }
        .frame(width: size.width, height: size.height)
        .animation(.easeOut(duration: 0.2), value: level)
    }

    private func lumen(_ values: [CGFloat], size: CGSize) -> some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                Capsule()
                    .fill(LumenGlass.jewels[index % LumenGlass.jewels.count].opacity(0.85))
                    .frame(height: max(6, value * size.height))
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Text input styled per look.
struct LookTextField: View {
    @Environment(\.look) private var look
    var placeholder: String
    @Binding var text: String
    var axis: Axis = .horizontal

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: look.shape.smallRadius, style: .continuous)
        TextField(placeholder, text: $text, axis: axis)
            .font(look.type.body)
            .foregroundStyle(look.palette.ink)
            .padding(12)
            .background {
                switch look.id {
                case .sower: shape.fill(look.palette.surfaceRaised).overlay(shape.strokeBorder(look.palette.ink.opacity(0.5), lineWidth: 1))
                case .riso: shape.fill(look.palette.surfaceRaised).overlay(shape.strokeBorder(look.palette.ink, lineWidth: 2))
                case .rubric: shape.fill(look.palette.surfaceRaised).overlay(shape.strokeBorder(look.palette.rule, lineWidth: 1))
                case .vespers: shape.fill(look.palette.surface).overlay(shape.strokeBorder(look.palette.rule, lineWidth: 1))
                case .lumen: shape.fill(.white.opacity(0.08)).overlay(shape.strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
                case .midnight: shape.fill(look.palette.surface).overlay(shape.strokeBorder(look.palette.rule, lineWidth: 1))
                }
            }
    }
}
