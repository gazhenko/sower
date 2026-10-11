import Foundation

extension SermonStore {
    /// The saved choice; resolution can fall back without discarding it.
    public func preferredListeningAssetID(for sermonID: UUID) -> UUID? {
        document.features?.preferredListeningAssets?[sermonID]
    }

    /// Resolve the saved local source, otherwise use the canonical original.
    public func preferredListeningAsset(for sermonID: UUID) -> AudioAsset? {
        let assets = audioAssets(for: sermonID)
        func playable(_ asset: AudioAsset) -> Bool {
            audioURL(for: asset) != nil && (asset.kind != .official || (try? requireOfficialAuthorization(asset.id)) != nil)
        }
        if let id = preferredListeningAssetID(for: sermonID), let asset = assets.first(where: { $0.id == id }), playable(asset) {
            return asset
        }
        guard let id = sermon(sermonID)?.canonicalAudioAssetID, let original = assets.first(where: { $0.id == id }), playable(original) else { return nil }
        return original
    }

    /// Passing nil resets listening to the canonical source. Sharing and ASR do not use this choice.
    public func setPreferredListeningAsset(_ assetID: UUID?, for sermonID: UUID) throws {
        _ = try requireSermon(sermonID)
        if let assetID {
            guard let asset = document.audio[assetID], asset.sermonID == sermonID, audioURL(for: asset) != nil else {
                throw report(SermonSetError(title: "Audio unavailable", message: "Choose an available audio source saved with this sermon."))
            }
            if asset.kind == .official { try requireOfficialAuthorization(asset.id) }
        }
        try transaction {
            if $0.features == nil { $0.features = CoreFeatures() }
            if $0.features?.preferredListeningAssets == nil { $0.features?.preferredListeningAssets = [:] }
            $0.features?.preferredListeningAssets?[sermonID] = assetID
        }
    }
}
