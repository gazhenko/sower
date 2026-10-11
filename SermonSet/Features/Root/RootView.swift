import SermonSetCore
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(\.look) private var look
    @Environment(SermonStore.self) private var store
    @Environment(CaptureController.self) private var capture
    @Environment(PlaybackController.self) private var playback
    @Environment(CommunityPlaybackController.self) private var communityPlayback
    @Environment(AppRouter.self) private var router
    @AppStorage("SermonSetOnboarded") private var onboarded = false
    @State private var importError: SermonSetError?
    @State private var isImporting = false
    @State private var afterOnboarding: OnboardingNext?
    @State private var chromeHeight: CGFloat = 0

    var body: some View {
        @Bindable var router = router
        ZStack {
            LookBackground()
            // Only the selected destination is in the hierarchy, so VoiceOver never reaches hidden
            // tabs. Each tab's navigation path lives in the router, so switching keeps your place.
            NavigationStack(path: router.path(for: router.tab)) {
                tabRoot(router.tab)
                    .background { LookBackground() }
                    .containerBackground(.clear, for: .navigation)
                    .sermonDestinations()
            }
            .id(router.tab)
            // The bar and mini player float over the tabs, so every scroll view ends clear of them.
            .contentMargins(.bottom, chromeHeight + 12, for: .scrollContent)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                if capture.isActive && !router.isRecorderPresented {
                    RecordingPill { router.isRecorderPresented = true }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if playback.nowPlayingSermonID != nil && !communityPlayback.isPlaying {
                    MiniPlayer()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    CommunityMiniPlayer()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                BottomBar()
            }
            .padding(.horizontal, look.id == .rubric || look.id == .sower ? 0 : 16)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chromeHeight = $0 }
            .animation(.snappy, value: capture.isActive)
            .animation(.snappy, value: playback.nowPlayingSermonID)
        }
        .fullScreenCover(isPresented: $router.isRecorderPresented) {
            RecordFlowView().lookScoped(look)
        }
        .fullScreenCover(isPresented: $router.isPackPresented) {
            PackOpeningView().lookScoped(look)
        }
        .fullScreenCover(item: cardViewerBinding) { item in
            CardViewer(sermonID: item.id).lookScoped(look)
        }
        .sheet(isPresented: $router.isSettingsPresented) {
            SettingsView().lookScoped(look)
        }
        .sheet(isPresented: $router.isInboxPresented) {
            InboxView().lookScoped(look)
        }
        .sheet(item: $router.communitySermon) { route in
            CommunitySermonSheet(sermonID: route.id).lookScoped(look)
        }
        .sheet(item: $router.incomingOffer) { offer in
            OfferReviewSheet(token: offer.token).lookScoped(look)
        }
        .sheet(item: openedOfferBinding) { item in
            OfferReviewSheet(offerID: item.id).lookScoped(look)
        }
        .fullScreenCover(isPresented: onboardingBinding, onDismiss: {
            // Present the next screen only after onboarding has fully left the screen.
            switch afterOnboarding {
            case .record: router.isRecorderPresented = true
            case .importAudio: router.isImporterPresented = true
            case nil: break
            }
            afterOnboarding = nil
        }) {
            OnboardingView { next in
                afterOnboarding = next
                onboarded = true
            }
            .lookScoped(look)
        }
        .fileImporter(isPresented: $router.isImporterPresented, allowedContentTypes: [.audio, .mpeg4Audio, .mp3, .wav, .aiff]) { result in
            handleImport(result)
        }
        .overlay {
            if isImporting {
                ImportingOverlay()
            }
        }
        .alert(item: errorBinding) { error in
            Alert(
                title: Text(error.title),
                message: Text([error.message, error.recoverySuggestion].compactMap { $0 }.joined(separator: "\n\n")),
                dismissButton: .default(Text("OK")) {
                    store.clearError()
                    importError = nil
                }
            )
        }
        .task { await store.refreshCapabilities() }
        .onAppear { DebugLaunchRoute.apply(router: router, store: store, capture: capture) }
        .onReceive(NotificationCenter.default.publisher(for: .debugPlay)) { note in
            if let id = note.object as? UUID { playback.play(sermonID: id, from: 20) }
        }
    }

    @ViewBuilder
    private func tabRoot(_ tab: AppTab) -> some View {
        switch tab {
        case .library: LibraryView()
        case .discover: DiscoverView()
        case .collection: CollectionView()
        }
    }

    private var onboardingBinding: Binding<Bool> {
        Binding(get: { !onboarded }, set: { onboarded = !$0 })
    }

    private var openedOfferBinding: Binding<CommunitySermonRoute?> {
        Binding(get: { router.openedOfferID.map(CommunitySermonRoute.init) }, set: { router.openedOfferID = $0?.id })
    }

    private var cardViewerBinding: Binding<IdentifiedUUID?> {
        Binding(
            get: { router.cardViewerSermonID.map(IdentifiedUUID.init) },
            set: { router.cardViewerSermonID = $0?.id }
        )
    }

    private var errorBinding: Binding<SermonSetError?> {
        Binding(get: { importError ?? store.lastError }, set: { if $0 == nil { importError = nil; store.clearError() } })
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            isImporting = true
            Task {
                defer { isImporting = false }
                do {
                    let sermon = try await store.importAudio(from: url, title: nil)
                    router.openSermon(sermon.id)
                } catch let error as SermonSetError {
                    importError = error
                } catch {
                    importError = SermonSetError(title: "Couldn’t import that file", message: error.localizedDescription)
                }
            }
        case .failure(let error):
            if (error as NSError).code != NSUserCancelledError {
                importError = SermonSetError(title: "Couldn’t open that file", message: error.localizedDescription)
            }
        }
    }
}

struct IdentifiedUUID: Identifiable, Hashable {
    let id: UUID
}

extension View {
    /// Presented views don't always inherit custom environment values reliably across
    /// full-screen covers, so each presentation re-applies the look explicitly.
    func lookScoped(_ look: Look) -> some View {
        environment(\.look, look)
            .preferredColorScheme(look.colorScheme)
            .tint(look.palette.accent)
    }
}

private struct ImportingOverlay: View {
    @Environment(\.look) private var look

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large).tint(look.palette.accent)
            Text("Copying audio to this iPhone…").font(look.type.callout).foregroundStyle(look.palette.ink)
        }
        .lookPanel(padding: 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.25))
        .accessibilityElement(children: .combine)
    }
}
