import AppKit
import CoreGraphics

/// Coarse category of the frontmost app, used for context-aware emotions.
enum AppCategory {
    case ide, terminal, video, music, social, game

    /// Sticker tags matching the mood this category implies.
    var emotionTags: [String] {
        switch self {
        case .ide, .terminal: return ["work"]
        case .video, .music: return ["lazy", "happy"]
        case .social: return ["love", "happy"]
        case .game: return ["happy"]
        }
    }
}

/// Tracks user input idle time and the frontmost application.
/// No system permissions required.
final class ActivityMonitor {

    /// Bundle ids considered "slacking" (video / entertainment apps).
    /// Browser-based video detection would need Accessibility permission;
    /// extend this set or add an AX-based checker later if wanted.
    static let slackBundleIDs: Set<String> = [
        "com.bilibili.bilibili",        // B站 mac 客户端
        "tv.danmaku.bilibilihd",
        "com.tencent.tenvideo",         // 腾讯视频
        "com.qiyi.player",              // 爱奇艺
        "com.youku.mac",                // 优酷
        "com.colliderli.iina",          // IINA
        "org.videolan.vlc",             // VLC
        "com.apple.TV",                 // Apple TV
        "com.netease.cloudmusic",       // 网易云（划水听歌看MV）
        "com.iqiyi.player",
    ]

    private(set) var frontBundleID: String?
    private var frontSince = Date()

    init() {
        frontBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func appActivated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication
        let id = app?.bundleIdentifier
        if id != frontBundleID {
            frontBundleID = id
            frontSince = Date()
        }
    }

    /// Continuous seconds the frontmost app has been a "slacking" app.
    var slackingSeconds: TimeInterval {
        guard let id = frontBundleID, Self.slackBundleIDs.contains(id) else {
            return 0
        }
        return Date().timeIntervalSince(frontSince)
    }

    /// Exact bundle-id → category mapping; unknown apps return nil.
    static let appCategories: [String: AppCategory] = [
        // IDE
        "com.apple.dt.Xcode": .ide,
        "com.microsoft.VSCode": .ide,
        "com.jetbrains.intellij": .ide,
        "com.jetbrains.pycharm": .ide,
        "com.jetbrains.WebStorm": .ide,
        "com.jetbrains.goland": .ide,
        "com.jetbrains.CLion": .ide,
        "com.jetbrains.rider": .ide,
        "com.jetbrains.datagrip": .ide,
        "com.jetbrains.rubymine": .ide,
        "com.jetbrains.PhpStorm": .ide,
        "com.jetbrains.AppCode": .ide,
        // Terminal
        "com.apple.Terminal": .terminal,
        "com.googlecode.iterm2": .terminal,
        // Video（与 slackBundleIDs 中的视频类一致）
        "com.bilibili.bilibili": .video,
        "tv.danmaku.bilibilihd": .video,
        "com.tencent.tenvideo": .video,
        "com.qiyi.player": .video,
        "com.youku.mac": .video,
        "com.colliderli.iina": .video,
        "org.videolan.vlc": .video,
        "com.apple.TV": .video,
        "com.iqiyi.player": .video,
        // Music
        "com.netease.cloudmusic": .music,
        "com.spotify.client": .music,
        // Social
        "com.tencent.xinWeChat": .social,
        "com.tencent.qq": .social,
        // Game
        "com.valvesoftware.steam": .game,
    ]

    /// Category of the frontmost app, nil when unknown.
    var frontCategory: AppCategory? {
        guard let id = frontBundleID else { return nil }
        return Self.appCategories[id]
    }

    /// Continuous seconds the frontmost app has been a categorized app.
    var frontCategorySeconds: TimeInterval {
        guard frontCategory != nil else { return 0 }
        return Date().timeIntervalSince(frontSince)
    }

    /// Seconds since the user last touched keyboard / mouse / trackpad.
    static func idleSeconds() -> TimeInterval {
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .rightMouseDown,
            .keyDown, .scrollWheel,
        ]
        let values = types.map {
            CGEventSource.secondsSinceLastEventType(
                .combinedSessionState, eventType: $0)
        }
        return values.min() ?? .infinity
    }
}
