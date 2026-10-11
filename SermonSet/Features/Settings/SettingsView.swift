import SermonSetCore
import SwiftUI

struct SettingsView: View {
    @Environment(\.look) private var look
    @Environment(\.dismiss) private var dismiss
    @Environment(SermonStore.self) private var store
    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var confirmErase = false

    var body: some View {
        NavigationStack {
            ZStack {
                LookBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        VStack(alignment: .leading, spacing: 12) {
                            LookSectionHeader("Look", detail: "The \(AppBrand.name) house look, plus five more. Everything works the same in each.")
                            LookPicker()
                            AppIconPicker()
                        }
                        CommunityAccountSection()
                        privacy
                        processing
                        samples
                        data
                        about
                    }
                    .padding(20)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .storeErrorAlert()
            .confirmationDialog("Erase everything on this iPhone?", isPresented: $confirmErase, titleVisibility: .visible) {
                Button("Erase all \(AppBrand.name) data", role: .destructive) { try? store.eraseAllData() }
            } message: {
                Text("Recordings, notes, moments, and cards will be deleted. This can’t be undone.")
            }
        }
    }

    // MARK: Privacy

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 14) {
            LookSectionHeader("Privacy and backup")
            VStack(alignment: .leading, spacing: 10) {
                PrivateBadge()
                Text("Recordings, transcripts, notes, and moments stay on this iPhone. \(AppBrand.name) never uploads anything on its own. Sharing is always something you choose, one sermon at a time.")
                    .font(look.type.callout)
                    .foregroundStyle(look.palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 0) {
                backupOption(.deviceBackup, title: "Include in iPhone backup", detail: "Recommended. Your recordings come back if you restore this iPhone.")
                backupOption(.excludeFromBackup, title: "Keep out of backups", detail: "Recordings exist only on this iPhone. If it’s lost, they’re gone.")
            }
            .lookPanel(padding: 6)
            BackupSection()
                .lookPanel(padding: 16)
        }
    }

    private func backupOption(_ preference: BackupPreference, title: String, detail: String) -> some View {
        let isOn = store.backupPreference == preference
        return Button {
            try? store.setBackupPreference(preference)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(isOn ? look.palette.accent : look.palette.inkTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(look.type.headline).foregroundStyle(look.palette.ink)
                    Text(detail).font(look.type.caption).foregroundStyle(look.palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: Processing

    private var processing: some View {
        VStack(alignment: .leading, spacing: 12) {
            LookSectionHeader("On-device processing")
            capability("Speech recognition", status: store.capabilities.speechTranscription, detail: "Turns recordings into a timed transcript.")
            if case .needsDownload = store.capabilities.speechTranscription {
                SpeechDownloadButton()
            }
            capability("Apple Intelligence model", status: store.capabilities.onDeviceLanguageModel, detail: "Writes sermon notes from the transcript. Without it, \(AppBrand.name) pulls key sentences instead and can’t write notes.")
            Toggle(isOn: Binding(get: { store.summarizeAfterRecording }, set: { store.summarizeAfterRecording = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Write sermon notes after recording").font(look.type.headline).foregroundStyle(look.palette.ink)
                    Text("When you stop, \(AppBrand.name) transcribes the sermon and writes notes on this iPhone: the big idea, the points, and what to do this week.")
                        .font(look.type.caption)
                        .foregroundStyle(look.palette.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(look.palette.accent)
            Toggle(isOn: Binding(get: { store.voiceFocusAfterRecording }, set: { store.voiceFocusAfterRecording = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Make a Voice Focus copy after recording").font(look.type.headline).foregroundStyle(look.palette.ink)
                    Text("Clearer speech for listening, at the recommended 50% with music left alone. Your original is kept, and transcripts always use it because it’s more accurate for the transcriber.")
                        .font(look.type.caption)
                        .foregroundStyle(look.palette.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(look.palette.accent)
            TranscriptionEngineSection().padding(.top, 6)
            NotesEngineSection().padding(.top, 6)
            Text("If something isn’t available here, \(AppBrand.name) skips it. It never sends your audio to a server instead.")
                .font(look.type.caption)
                .foregroundStyle(look.palette.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func capability(_ title: String, status: CapabilityStatus, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: status.isAvailable ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(status.isAvailable ? look.palette.positive : look.palette.inkTertiary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(look.type.headline).foregroundStyle(look.palette.ink)
                Text(status.displayText).font(look.type.callout).foregroundStyle(look.palette.inkSecondary)
                Text(detail).font(look.type.caption).foregroundStyle(look.palette.inkTertiary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Samples & data

    private var samples: some View {
        VStack(alignment: .leading, spacing: 10) {
            LookSectionHeader("Sample sermons")
            Text("Eight fictional sermons with narrated audio, so you can try everything before recording.")
                .font(look.type.callout)
                .foregroundStyle(look.palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if store.hasSamplesInLibrary {
                Button("Remove samples from my library") { try? store.removeSampleSermons() }
                    .buttonStyle(.look(.secondary))
            } else {
                Button("Add sample sermons") { try? store.addSampleSermons() }
                    .buttonStyle(.look(.secondary))
            }
        }
    }

    private var data: some View {
        VStack(alignment: .leading, spacing: 10) {
            LookSectionHeader("Your data")
            if let exportURL {
                ShareLink(item: exportURL) {
                    Label("Share export file", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.look(.primary))
            } else {
                Button("Export my library") {
                    do { exportURL = try store.exportArchive() } catch { exportError = error.localizedDescription }
                }
                .buttonStyle(.look(.secondary))
            }
            Text("The export is a file with your library, notes, and moments. It includes private notes, so keep it somewhere safe. Audio isn’t included.")
                .font(look.type.caption)
                .foregroundStyle(look.palette.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let exportError {
                Text(exportError).font(look.type.caption).foregroundStyle(look.palette.record)
            }
            Button("Erase all data", role: .destructive) { confirmErase = true }
                .buttonStyle(.look(.quiet))
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 10) {
            LookSectionHeader("About")
            Text(AppBrand.tagline)
                .font(look.type.title)
                .lookDisplay(look)
                .foregroundStyle(look.palette.ink)
            VStack(alignment: .leading, spacing: 6) {
                Text(AppBrand.principle)
                Text("Every feature is free, with no ads or purchases.")
                Text("Trading a card never removes a sermon from your library.")
                Text("Your notes never travel with a card.")
                Text("Recording for yourself isn’t permission to share.")
            }
            .font(look.type.callout)
            .foregroundStyle(look.palette.inkSecondary)
            NavigationLink("Card lab") { LookLab(models: LookLab.sampleModels(store)) }
                .font(look.type.callout)
                .foregroundStyle(look.palette.accent)
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"). Sample churches, preachers, and sermons are fictional.")
                .font(look.type.caption)
                .foregroundStyle(look.palette.inkTertiary)
        }
    }
}

/// Live previews of every look; choosing one restyles the whole app immediately.
struct LookPicker: View {
    @Environment(SermonStore.self) private var store
    @AppStorage(LookID.storageKey) private var lookRaw = LookID.sower.rawValue

    var body: some View {
        let model = store.discoverCatalog.first.map { CardFaceModel(sermon: $0, store: store) } ?? .preview
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
            ForEach(LookID.allCases) { id in
                LookTile(id: id, model: model, isSelected: lookRaw == id.rawValue) {
                    withAnimation(.easeInOut(duration: 0.25)) { lookRaw = id.rawValue }
                }
            }
        }
    }
}

struct LookTile: View {
    var id: LookID
    var model: CardFaceModel
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        let look = Look.of(id)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                SermonCardFace(model: model, side: .front, lookID: id)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(look.name).font(look.type.headline).foregroundStyle(look.palette.ink)
                    Text(look.tagline).font(look.type.caption).foregroundStyle(look.palette.inkSecondary).lineLimit(2)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    LookBackground()
                }
                .environment(\.look, look)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isSelected ? look.palette.accent : Color.gray.opacity(0.3), lineWidth: isSelected ? 3 : 1)
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(look.palette.onAccent, look.palette.accent)
                        .font(.title2)
                        .padding(8)
                }
            }
            .environment(\.colorScheme, look.colorScheme)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(look.name) look. \(look.story)"))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// Lets the home-screen icon match a look. Changing it is always the listener's explicit choice.
struct AppIconPicker: View {
    @Environment(\.look) private var look
    @State private var current: String? = UIApplication.shared.alternateIconName
    @State private var failure: String?

    private func iconName(_ id: LookID) -> String? {
        id == .sower ? nil : "AppIcon-\(Look.of(id).name)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("App icon").font(look.type.headline).foregroundStyle(look.palette.ink)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 14) {
                ForEach(LookID.allCases) { id in
                    let isOn = current == iconName(id)
                    Button {
                        guard UIApplication.shared.supportsAlternateIcons else { return }
                        UIApplication.shared.setAlternateIconName(iconName(id)) { error in
                            Task { @MainActor in
                                if let error { failure = error.localizedDescription } else { current = iconName(id) }
                            }
                        }
                    } label: {
                        VStack(spacing: 6) {
                            Image("IconPreview-\(id.rawValue)")
                                .resizable()
                                .aspectRatio(1, contentMode: .fit)
                                .frame(width: 58, height: 58)
                                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                                        .strokeBorder(isOn ? look.palette.accent : look.palette.rule, lineWidth: isOn ? 3 : 1)
                                )
                            Text(Look.of(id).name).font(look.type.caption).foregroundStyle(look.palette.inkSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("\(Look.of(id).name) app icon"))
                    .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
                }
            }
            if let failure {
                Text(failure).font(look.type.caption).foregroundStyle(look.palette.record)
            }
        }
        .padding(.top, 6)
    }
}
