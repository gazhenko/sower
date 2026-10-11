import SermonSetCore
import SwiftUI

/// The sermon as a listener would write it down: the big idea, the preacher's points in order with their
/// key phrases and scripture, what to do this week, and questions to sit with. Drafted on this iPhone by
/// Apple Intelligence; every point and key phrase plays the moment it came from.
struct SermonNotesSection: View {
    @Environment(\.look) private var look
    @Environment(SermonStore.self) private var store
    @Environment(PlaybackController.self) private var playback
    var sermon: Sermon
    @State private var isEditing = false
    @State private var confirmRedo = false
    @State private var actionError: String?

    private var canEdit: Bool { store.isInLibrary(sermon.id) }

    var body: some View {
        let insights = store.insights(for: sermon.id)
        if canEdit || insights?.notes != nil {
            VStack(alignment: .leading, spacing: 18) {
                LookSectionHeader("Sermon notes")
                if let notes = insights?.notes {
                    if store.jobs(for: sermon.id).summary.isRunning {
                        NotesProgress(sermonID: sermon.id)
                    }
                    notesBody(notes)
                } else {
                    NotesStart(sermon: sermon, reason: insights?.notesUnavailableReason, hasLegacySummary: insights?.summary != nil)
                }
                if let actionError {
                    Label(actionError, systemImage: "exclamationmark.triangle")
                        .font(look.type.caption)
                        .foregroundStyle(look.palette.record)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .sheet(isPresented: $isEditing) {
                if let notes = insights?.notes {
                    SermonNotesEditor(sermonID: sermon.id, notes: notes)
                }
            }
            .confirmationDialog("Write the notes again?", isPresented: $confirmRedo, titleVisibility: .visible) {
                Button("Replace my edits", role: .destructive) { redo() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Apple Intelligence will read the transcript again. Your edited notes will be replaced.")
            }
        }
    }

    // MARK: Notes

    @ViewBuilder
    private func notesBody(_ notes: SermonNotes) -> some View {
        let busy = store.jobs(for: sermon.id).summary.isRunning
        VStack(alignment: .leading, spacing: 22) {
            meta(notes)
            if canEdit, let suggested = notes.title, !suggested.isEmpty, sermon.title.trimmingCharacters(in: .whitespaces).isEmpty {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Suggested title").font(look.type.caption).foregroundStyle(look.palette.inkTertiary)
                        Text(suggested).font(look.type.headline).foregroundStyle(look.palette.ink)
                    }
                    Spacer()
                    Button("Use it") {
                        var renamed = sermon
                        renamed.title = suggested
                        perform { try store.updateSermon(renamed) }
                    }
                    .buttonStyle(.look(.secondary))
                }
                .lookPanel(padding: 14)
            }
            BigIdea(text: notes.bigIdea)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(notes.points.enumerated()), id: \.element.id) { index, point in
                    SermonPointRow(index: index + 1, point: point) { start in
                        playback.play(sermonID: sermon.id, from: start)
                    }
                }
            }

            if !notes.thisWeek.isEmpty {
                ThisWeekList(sermonID: sermon.id, items: notes.thisWeek)
            }

            if !notes.questions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    NotesLabel(text: "To reflect on")
                    ForEach(Array(notes.questions.enumerated()), id: \.offset) { _, question in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(verbatim: look.id == .midnight ? "?" : "·").foregroundStyle(look.palette.accent)
                            Text(question)
                                .font(look.type.body.italic())
                                .foregroundStyle(look.palette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            Text(provenance(notes))
                .font(look.type.caption)
                .foregroundStyle(look.palette.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if canEdit {
                actions(notes).disabled(busy)
            }
        }
        .opacity(busy ? 0.5 : 1)
    }

    /// Passage and how many points, the way a bulletin heads its sermon outline.
    private func meta(_ notes: SermonNotes) -> some View {
        FlowLayout(spacing: 8) {
            if let passage = notes.mainPassage ?? sermon.primaryPassage, !passage.isEmpty {
                LookTag(text: passage, color: look.palette.accent, systemImage: "book.closed")
            }
            if !notes.points.isEmpty {
                LookTag(text: notes.pointsAnnounced
                        ? "The preacher’s \(notes.points.count) points"
                        : "\(notes.points.count) main ideas")
            }
        }
    }

    private func actions(_ notes: SermonNotes) -> some View {
        let onCard = sermon.summary == notes.bigIdea
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if onCard {
                    Label("On your card", systemImage: "checkmark")
                        .font(look.type.callout)
                        .foregroundStyle(look.palette.positive)
                } else {
                    Button("Use on card") { perform { try store.useNotesOnCard(sermonID: sermon.id) } }
                        .buttonStyle(.look(.primary))
                }
                ShareLink(item: NotesText.plain(notes, sermon: sermon)) {
                    Label("Share notes", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.look(.secondary))
            }
            HStack(spacing: 16) {
                Button("Edit") { isEditing = true }
                Button("Write again") { notes.isEdited ? (confirmRedo = true) : redo() }
                    .accessibilityHint("Apple Intelligence reads the transcript again and writes new notes")
            }
            .font(look.type.callout.weight(.semibold))
            .foregroundStyle(look.palette.inkSecondary)
            .buttonStyle(.plain)
        }
    }

    private func redo() {
        actionError = nil
        Task { await store.regenerateNotes(sermonID: sermon.id) }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); actionError = nil } catch {
            actionError = (error as? SermonSetError)?.message ?? error.localizedDescription
        }
    }

    private func provenance(_ notes: SermonNotes) -> String {
        if sermon.isSample { return "Written for this sample. Key phrases are the sample’s own words; tap one to hear it." }
        if notes.isEdited { return "Edited by you. Key phrases are still the preacher’s exact words." }
        return "Drafted on this iPhone by Apple Intelligence from the transcript. Key phrases are the preacher’s exact words; tap a time to hear it."
    }
}

// MARK: - Points

/// One point: its number, a heading, what it means, the preacher's own words, and the scripture behind it.
struct SermonPointRow: View {
    @Environment(\.look) private var look
    var index: Int
    var point: SermonPoint
    var onPlay: (TimeInterval) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            PointMarker(index: index)
                .frame(minWidth: 30, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(point.heading)
                        .font(headingFont)
                        .lookDisplay(look)
                        .foregroundStyle(look.palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button { onPlay(point.start) } label: {
                        Label(Format.clock(point.start), systemImage: "play.fill")
                            .labelStyle(.titleAndIcon)
                            .font(look.type.caption.weight(.semibold).monospacedDigit())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(look.palette.accent)
                    .accessibilityLabel(Text("Play point \(index) from \(Format.spokenClock(point.start))"))
                }
                Text(point.summary)
                    .font(look.type.body)
                    .foregroundStyle(look.palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let phrase = point.keyPhrase {
                    KeyPhraseQuote(phrase: phrase, onPlay: onPlay)
                }
                if !point.scripture.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(point.scripture, id: \.self) { LookTag(text: $0) }
                    }
                }
            }
        }
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Rectangle().fill(look.palette.rule).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }

    private var headingFont: Font {
        switch look.id {
        case .sower: SowerType.display(28, .title3, weight: .regular)
        case .riso: .custom("Futura-CondensedExtraBold", 24, .title3)
        case .rubric: .custom("IowanOldStyle-Bold", 20, .title3)
        case .vespers: .custom("Optima-Bold", 19, .title3)
        case .lumen: .system(.title3, weight: .bold).width(.expanded)
        case .midnight: MidnightType.mono(17, .headline, weight: .bold)
        }
    }
}

/// The preacher's exact words, set apart like a pull quote. Tapping plays them.
struct KeyPhraseQuote: View {
    @Environment(\.look) private var look
    var phrase: KeyPhrase
    var onPlay: (TimeInterval) -> Void

    var body: some View {
        Button { onPlay(phrase.start) } label: {
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(look.palette.accent).frame(width: look.id == .riso ? 4 : 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(look.id == .midnight ? "> \(phrase.text)" : "“\(phrase.text)”")
                        .font(look.type.callout.italic())
                        .foregroundStyle(look.palette.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Key phrase · \(Format.clock(phrase.start))")
                        .font(look.type.caption)
                        .foregroundStyle(look.palette.inkTertiary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Key phrase: \(phrase.text)"))
        .accessibilityHint(Text("Plays it at \(Format.spokenClock(phrase.start))"))
    }
}

/// The point number in each look's numerals.
struct PointMarker: View {
    @Environment(\.look) private var look
    var index: Int

    var body: some View {
        switch look.id {
        case .sower:
            Text("\(index)").font(SowerType.display(44, .title, weight: .ultraLight)).foregroundStyle(look.palette.accent).offset(y: -2)
        case .riso:
            Text("\(index)").font(.custom("Futura-CondensedExtraBold", 34, .title))
                .foregroundStyle(look.palette.ink)
                .padding(.horizontal, 6)
                .background(look.palette.moment, in: RoundedRectangle(cornerRadius: 4))
        case .rubric:
            Text("\(roman(index)).").font(.custom("IowanOldStyle-Bold", 20, .title3)).foregroundStyle(look.palette.accent)
        case .vespers:
            Text("\(index)").font(.custom("Optima-Regular", 28, .title2)).foregroundStyle(look.palette.accent)
        case .lumen:
            Text("\(index)").font(.system(.title, weight: .heavy).width(.expanded)).foregroundStyle(look.palette.accent)
        case .midnight:
            Text(verbatim: "[\(index)]").font(MidnightType.mono(17, .headline, weight: .bold)).foregroundStyle(look.palette.accent)
        }
    }

    private func roman(_ n: Int) -> String {
        ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X"].indices.contains(n - 1) ? ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X"][n - 1] : "\(n)"
    }
}

/// Small section label inside the notes, styled per look.
struct NotesLabel: View {
    @Environment(\.look) private var look
    var text: String

    var body: some View {
        Text(look.id == .midnight ? "// \(text.lowercased())" : text)
            .font(look.id == .midnight ? look.type.caption : look.type.label)
            .foregroundStyle(look.palette.inkTertiary)
    }
}

/// What to do this week, checkable. Checks are a private convenience kept on this iPhone.
struct ThisWeekList: View {
    @Environment(\.look) private var look
    var sermonID: UUID
    var items: [String]
    @State private var done: Set<Int> = []

    private var key: String { "sermon-notes-done-\(sermonID.uuidString)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NotesLabel(text: "This week")
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                Button {
                    if done.contains(index) { done.remove(index) } else { done.insert(index) }
                    UserDefaults.standard.set(Array(done), forKey: key)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: done.contains(index) ? "checkmark.square.fill" : "square")
                            .foregroundStyle(done.contains(index) ? look.palette.positive : look.palette.accent)
                        Text(item)
                            .font(look.type.body)
                            .foregroundStyle(done.contains(index) ? look.palette.inkTertiary : look.palette.ink)
                            .strikethrough(done.contains(index), color: look.palette.inkTertiary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(done.contains(index) ? [.isSelected, .isButton] : .isButton)
                .accessibilityValue(done.contains(index) ? "Done" : "Not done")
            }
        }
        .onAppear { done = Set(UserDefaults.standard.array(forKey: key) as? [Int] ?? []) }
    }
}

// MARK: - Big idea, progress, start

/// The one sentence to carry out of the room, set in each look's display type.
struct BigIdea: View {
    @Environment(\.look) private var look
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NotesLabel(text: "The big idea")
            Text(text)
                .font(font)
                .lookDisplay(look)
                .foregroundStyle(look.palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var font: Font {
        switch look.id {
        case .sower: SowerType.display(34, .title2, weight: .light)
        case .riso: .custom("Futura-CondensedExtraBold", 28, .title2)
        default: look.type.title
        }
    }
}

/// Where the after-recording work is up to, in the store's own words. Never claims progress it hasn't made.
struct NotesProgress: View {
    @Environment(\.look) private var look
    @Environment(SermonStore.self) private var store
    var sermonID: UUID

    var body: some View {
        let jobs = store.jobs(for: sermonID)
        let transcribing = jobs.transcription.isRunning
        let writing = !transcribing && (jobs.insights.isRunning || jobs.summary.isRunning)
        let progress = transcribing ? jobs.transcription.progress : (jobs.summary.isRunning ? jobs.summary.progress : jobs.insights.progress)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                step(1, "Transcribe", active: transcribing, done: writing)
                Rectangle().fill(look.palette.rule).frame(height: 1).frame(maxWidth: 28)
                step(2, "Write notes", active: writing, done: false)
            }
            HStack(spacing: 8) {
                ProgressView().tint(look.palette.accent)
                Text(transcribing ? "Transcribing on this iPhone" : writing ? (store.notesStageDetail ?? "Writing the notes") : "Getting ready")
                    .font(look.type.headline)
                    .foregroundStyle(look.palette.ink)
            }
            if let progress {
                if look.id == .midnight { MidnightProgressBar(value: progress, width: 22) } else { ProgressTrack(value: progress) }
            }
            Text("You can leave this screen. It keeps going on this iPhone, and nothing is uploaded.")
                .font(look.type.caption)
                .foregroundStyle(look.palette.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .lookPanel(padding: 16)
        .accessibilityElement(children: .combine)
    }

    private func step(_ number: Int, _ title: LocalizedStringKey, active: Bool, done: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle\(active ? ".fill" : "")")
                .foregroundStyle(done || active ? look.palette.accent : look.palette.inkTertiary)
            Text(title)
                .font(look.type.callout.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? look.palette.ink : look.palette.inkSecondary)
        }
    }
}

/// Before there are notes: start them, show where they're up to, or explain plainly why they can't run here.
struct NotesStart: View {
    @Environment(\.look) private var look
    @Environment(SermonStore.self) private var store
    var sermon: Sermon
    var reason: String?
    var hasLegacySummary = false

    var body: some View {
        let jobs = store.jobs(for: sermon.id)
        let hasTranscript = store.transcript(for: sermon.id) != nil
        let model = store.capabilities.onDeviceLanguageModel
        let failure = jobs.transcription.message ?? jobs.insights.message ?? jobs.summary.message ?? jobs.transcription.unavailableReason
        if jobs.transcription.isRunning || jobs.insights.isRunning || jobs.summary.isRunning {
            NotesProgress(sermonID: sermon.id)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(look.type.callout)
                        .foregroundStyle(look.palette.record)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let reason, hasTranscript {
                    Label(reason, systemImage: "info.circle")
                        .font(look.type.callout)
                        .foregroundStyle(look.palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(hasLegacySummary
                         ? "Sermon notes are new: the big idea, the preacher’s points with their key phrases, and what to do this week. Write them from this sermon’s transcript."
                         : hasTranscript
                         ? "The transcript is ready. Apple Intelligence can write sermon notes from it on this iPhone: the big idea, each point with its key phrase, and what to do this week."
                         : "Get sermon notes written on this iPhone by Apple Intelligence: the big idea, each point with its key phrase, and what to do this week. Nothing is uploaded.")
                        .font(look.type.callout)
                        .foregroundStyle(look.palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let fallback = store.transcriptionFallbackReason {
                    Label(fallback, systemImage: "info.circle")
                        .font(look.type.caption)
                        .foregroundStyle(look.palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !model.isAvailable {
                    AppleIntelligenceNote(status: model)
                }
                if !hasTranscript {
                    LanguagePicker(sermonID: sermon.id)
                }
                if case .unavailable(let why) = store.capabilities.speechTranscription, !hasTranscript {
                    Text(why).font(look.type.headline).foregroundStyle(look.palette.inkSecondary)
                } else {
                    Button {
                        Task {
                            if hasTranscript, store.insights(for: sermon.id) != nil {
                                await store.regenerateNotes(sermonID: sermon.id)
                            } else {
                                await store.processRecording(sermonID: sermon.id)
                            }
                        }
                    } label: {
                        Text(failure != nil || reason != nil ? "Try again" : "Write sermon notes")
                    }
                    .buttonStyle(.look(.primary))
                }
                Text("Your recording, moments, and notes work without any of this.")
                    .font(look.type.caption)
                    .foregroundStyle(look.palette.inkTertiary)
            }
            .lookPanel(padding: 16)
        }
    }
}

/// Plain directions for turning on Apple Intelligence; the notes need it, nothing else does.
struct AppleIntelligenceNote: View {
    @Environment(\.look) private var look
    var status: CapabilityStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Apple Intelligence: \(status.displayText)", systemImage: "circle.dashed")
                .font(look.type.callout.weight(.semibold))
                .foregroundStyle(look.palette.ink)
            Text(advice)
                .font(look.type.caption)
                .foregroundStyle(look.palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var advice: String {
        switch status {
        case .needsDownload:
            "Apple Intelligence is still downloading. Keep your iPhone on Wi‑Fi and charging, then try again."
        default:
            "To get sermon notes, turn on Apple Intelligence in Settings › Apple Intelligence & Siri. Without it, \(AppBrand.name) still transcribes and pulls key sentences, but can’t write notes."
        }
    }
}

// MARK: - Editing

/// Rewrite any part of the notes. Key phrases stay the preacher's words and aren't editable.
struct SermonNotesEditor: View {
    @Environment(\.look) private var look
    @Environment(\.dismiss) private var dismiss
    @Environment(SermonStore.self) private var store
    var sermonID: UUID
    @State var notes: SermonNotes
    @State private var thisWeek = ""
    @State private var questions = ""
    @State private var error: String?

    init(sermonID: UUID, notes: SermonNotes) {
        self.sermonID = sermonID
        _notes = State(initialValue: notes)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LookBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        field("The big idea", hint: "One sentence to carry out of the room.") {
                            LookTextField(placeholder: "The big idea", text: $notes.bigIdea, axis: .vertical)
                        }
                        ForEach($notes.points) { $point in
                            let number = (notes.points.firstIndex { $0.id == point.id } ?? 0) + 1
                            field("Point \(number)", hint: "A short heading, then what it means.") {
                                VStack(spacing: 8) {
                                    LookTextField(placeholder: "Heading", text: $point.heading)
                                    LookTextField(placeholder: "What it means", text: $point.summary, axis: .vertical)
                                }
                            }
                        }
                        field("This week", hint: "One per line.") {
                            LookTextField(placeholder: "Something to do", text: $thisWeek, axis: .vertical)
                        }
                        field("To reflect on", hint: "One question per line.") {
                            LookTextField(placeholder: "A question", text: $questions, axis: .vertical)
                        }
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(look.type.caption)
                                .foregroundStyle(look.palette.record)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Edit notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(notes.bigIdea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear {
            thisWeek = notes.thisWeek.joined(separator: "\n")
            questions = notes.questions.joined(separator: "\n")
        }
    }

    private func field(_ title: LocalizedStringKey, hint: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(look.type.headline).foregroundStyle(look.palette.ink)
            Text(hint).font(look.type.caption).foregroundStyle(look.palette.inkTertiary)
            content()
        }
    }

    private func save() {
        func lines(_ text: String) -> [String] {
            text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        var edited = notes
        edited.thisWeek = lines(thisWeek)
        edited.questions = lines(questions)
        do {
            try store.editNotes(sermonID: sermonID, notes: edited)
            dismiss()
        } catch {
            self.error = (error as? SermonSetError)?.message ?? error.localizedDescription
        }
    }
}

// MARK: - Sharing

/// The notes as plain text for Messages, Notes, or email. Sharing is always the listener's explicit choice.
enum NotesText {
    static func plain(_ notes: SermonNotes, sermon: Sermon) -> String {
        var lines: [String] = []
        lines.append([Format.title(sermon), sermon.preacher].compactMap { $0 }.joined(separator: " — "))
        if let passage = notes.mainPassage ?? sermon.primaryPassage { lines.append(passage) }
        lines.append("")
        lines.append("The big idea: \(notes.bigIdea)")
        for (index, point) in notes.points.enumerated() {
            lines.append("")
            lines.append("\(index + 1). \(point.heading)")
            lines.append("   \(point.summary)")
            if let phrase = point.keyPhrase { lines.append("   “\(phrase.text)” (\(Format.clock(phrase.start)))") }
            if !point.scripture.isEmpty { lines.append("   \(point.scripture.joined(separator: ", "))") }
        }
        if !notes.thisWeek.isEmpty {
            lines.append("")
            lines.append("This week:")
            lines += notes.thisWeek.map { "- \($0)" }
        }
        if !notes.questions.isEmpty {
            lines.append("")
            lines.append("To reflect on:")
            lines += notes.questions.map { "- \($0)" }
        }
        lines.append("")
        lines.append("Notes from \(AppBrand.name), written on iPhone.")
        return lines.joined(separator: "\n")
    }
}

extension JobState {
    var isRunning: Bool { if case .running = self { true } else { false } }
    var progress: Double? { if case .running(let progress) = self { progress } else { nil } }
    var message: String? { if case .failed(let message) = self { message } else { nil } }
    var unavailableReason: String? { if case .unavailable(let reason) = self { reason } else { nil } }
}
