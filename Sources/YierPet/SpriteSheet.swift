import AppKit

/// Animation states matching the hatch-pet 8x9 atlas contract.
/// Atlas: 8 columns x 9 rows, 192x208 px per cell.
enum PetState: String, CaseIterable {
    case idle
    case runningRight = "running-right"
    case runningLeft = "running-left"
    case waving
    case jumping
    case failed
    case waiting
    case running
    case review

    var row: Int {
        switch self {
        case .idle: return 0
        case .runningRight: return 1
        case .runningLeft: return 2
        case .waving: return 3
        case .jumping: return 4
        case .failed: return 5
        case .waiting: return 6
        case .running: return 7
        case .review: return 8
        }
    }

    /// Per-frame durations in milliseconds (from animation-rows.md).
    var durations: [Int] {
        switch self {
        case .idle: return [280, 110, 110, 140, 140, 320]
        case .runningRight, .runningLeft:
            return [120, 120, 120, 120, 120, 120, 120, 220]
        case .waving: return [140, 140, 140, 280]
        case .jumping: return [140, 140, 140, 140, 280]
        case .failed: return [140, 140, 140, 140, 140, 140, 140, 240]
        case .waiting: return [150, 150, 150, 150, 150, 260]
        case .running: return [120, 120, 120, 120, 120, 220]
        case .review: return [150, 150, 150, 150, 150, 280]
        }
    }

    var displayName: String {
        switch self {
        case .idle: return "待机"
        case .runningRight: return "向右跑"
        case .runningLeft: return "向左跑"
        case .waving: return "挥手"
        case .jumping: return "跳跃"
        case .failed: return "沮丧"
        case .waiting: return "等待"
        case .running: return "工作中"
        case .review: return "审阅"
        }
    }
}

/// Loads the spritesheet and slices per-state frames.
final class SpriteSheet {
    static let columns = 8
    static let cellWidth = 192
    static let cellHeight = 208

    private var frames: [PetState: [CGImage]] = [:]

    init?() {
        guard let url = Self.locateSheet(),
              let image = NSImage(contentsOf: url) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return nil
        }
        let scaleX = CGFloat(cg.width) / CGFloat(Self.columns * Self.cellWidth)
        let scaleY = CGFloat(cg.height) / CGFloat(9 * Self.cellHeight)
        for state in PetState.allCases {
            var list: [CGImage] = []
            for col in 0..<state.durations.count {
                let crop = CGRect(
                    x: CGFloat(col * Self.cellWidth) * scaleX,
                    y: CGFloat(state.row * Self.cellHeight) * scaleY,
                    width: CGFloat(Self.cellWidth) * scaleX,
                    height: CGFloat(Self.cellHeight) * scaleY
                )
                if let frame = cg.cropping(to: crop) {
                    list.append(frame)
                }
            }
            frames[state] = list
        }
    }

    /// Look up spritesheet.webp in the app bundle, next to the executable,
    /// or in a sibling Resources directory.
    private static func locateSheet() -> URL? {
        if let url = Bundle.main.url(forResource: "spritesheet", withExtension: "webp") {
            return url
        }
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        let candidates = [
            exeDir.appendingPathComponent("spritesheet.webp"),
            exeDir.deletingLastPathComponent()
                .appendingPathComponent("Resources/spritesheet.webp"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func frames(for state: PetState) -> [CGImage] {
        frames[state] ?? []
    }
}
