#if DEBUG
import ImagePlayground
import SermonSetCore
import SwiftUI
import UniformTypeIdentifiers

/// Research only (`-SermonSetScreen card-art-lab`): asks Apple's on-device Image Playground model to illustrate
/// each sample sermon from its notes, in the on-device styles, and saves PNGs to Documents/CardArtLab.
enum CardArtLab {
    @MainActor static func run(store: SermonStore) async {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("CardArtLab", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var log: [String] = []
        do {
            let creator = try await ImageCreator()
            log.append("styles: \(creator.availableStyles.map(\.id))")
            for sermon in store.discoverCatalog.prefix(4) {
                let notes = store.insights(for: sermon.id)?.notes
                let text = [notes?.bigIdea, notes?.points.map(\.heading).joined(separator: ". ")].compactMap { $0 }.joined(separator: " ")
                let source = text.isEmpty ? (sermon.summary ?? sermon.title) : text
                for style in [ImagePlaygroundStyle.illustration, .sketch] where creator.availableStyles.contains(style) {
                    let started = Date()
                    do {
                        for try await image in creator.images(for: [.extracted(from: source, title: sermon.title)], style: style, limit: 1) {
                            let name = "\(sermon.title.replacingOccurrences(of: " ", with: "-"))-\(style.id).png"
                            if let dest = CGImageDestinationCreateWithURL(folder.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil) {
                                CGImageDestinationAddImage(dest, image.cgImage, nil); CGImageDestinationFinalize(dest)
                            }
                            log.append("\(name) \(image.cgImage.width)x\(image.cgImage.height) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s from: \(source.prefix(80))")
                        }
                    } catch { log.append("\(sermon.title) \(style.id) failed: \(error)") }
                }
            }
        } catch { log.append("ImageCreator unavailable: \(error)") }
        try? log.joined(separator: "\n").write(to: folder.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
        NSLog("[card-art-lab] done: %@", log.joined(separator: " | "))
    }
}
#endif
