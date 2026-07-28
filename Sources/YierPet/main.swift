import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: PetController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let sheet = SpriteSheet() else {
            let alert = NSAlert()
            alert.messageText = "无法加载精灵图集"
            alert.informativeText = "spritesheet.webp 缺失或解码失败。"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        controller = PetController(sheet: sheet)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no Dock icon, no menu bar takeover
let delegate = AppDelegate()
app.delegate = delegate
app.run()
