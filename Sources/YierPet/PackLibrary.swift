import AppKit

/// The four switchable pet appearances.
enum PetStyle: String, CaseIterable {
    case classic
    case yier
    case bubu
    case duo

    var displayName: String {
        switch self {
        case .classic: return "经典一二"
        case .yier: return "活力一二"
        case .bubu: return "活力布布"
        case .duo: return "一二布布"
        }
    }

    /// Sticker styles play frame-sequence animations instead of the atlas.
    var isSticker: Bool { self != .classic }

    private static let defaultsKey = "pet.style"

    static var saved: PetStyle {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let style = PetStyle(rawValue: raw) else { return .classic }
            return style
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

/// One animated sticker: a directory of frame_NNN.png files.
struct Sticker {
    let id: String
    let fps: Double
    let frameCount: Int
    let tags: [String]
    let directory: URL

    /// Frames are loaded on demand so we never hold the whole pack in memory.
    func loadFrames() -> [CGImage] {
        var frames: [CGImage] = []
        for i in 0..<frameCount {
            let url = directory.appendingPathComponent(
                String(format: "frame_%03d.png", i))
            guard let image = NSImage(contentsOf: url) else { continue }
            var rect = CGRect(origin: .zero, size: image.size)
            if let cg = image.cgImage(
                forProposedRect: &rect, context: nil, hints: nil) {
                frames.append(cg)
            }
        }
        return frames
    }
}

/// Loads a sticker pack (meta.json + sticker directories) for one style.
final class PackLibrary {
    private let stickers: [Sticker]

    private struct Meta: Decodable {
        struct Entry: Decodable {
            let id: String
            let fps: Double
            let frames: Int
            let tags: [String]
        }
        let pack: String
        let stickers: [Entry]
    }

    init?(style: PetStyle) {
        guard style.isSticker,
              let packDir = Self.locatePacks()?
                  .appendingPathComponent(style.rawValue) else { return nil }
        let metaURL = packDir.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(Meta.self, from: data),
              !meta.stickers.isEmpty else { return nil }
        stickers = meta.stickers.map {
            Sticker(
                id: $0.id, fps: $0.fps, frameCount: $0.frames, tags: $0.tags,
                directory: packDir.appendingPathComponent($0.id))
        }
    }

    /// Look up the Packs directory in the app bundle, next to the
    /// executable, or in the source tree (direct binary runs).
    private static func locatePacks() -> URL? {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Packs"),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        let candidates = [
            exeDir.appendingPathComponent("Packs"),
            exeDir.deletingLastPathComponent()
                .appendingPathComponent("Resources/Packs"),
            exeDir.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Assets/Packs"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Random sticker for the first tag that has any match; nil if none.
    /// Tag order expresses fallback preference, e.g. ["hot", "angry", "idle"].
    func randomSticker(anyOf tags: [String]) -> Sticker? {
        for tag in tags {
            let pool = stickers.filter { $0.tags.contains(tag) }
            if let pick = pool.randomElement() { return pick }
        }
        return stickers.randomElement()
    }
}
