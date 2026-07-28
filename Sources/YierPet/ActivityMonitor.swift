import AppKit
import CoreGraphics

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
