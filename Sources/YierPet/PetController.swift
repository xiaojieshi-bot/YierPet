import AppKit

/// The view that renders animation frames and handles mouse interaction.
final class PetView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    /// Called on drag release with the release velocity in points/second.
    var onDragEnd: ((CGVector) -> Void)?
    var onClick: (() -> Void)?
    var menuProvider: (() -> NSMenu)?

    private let spriteLayer = CALayer()
    private var dragged = false
    /// Recent drag deltas used to estimate throw velocity.
    private var dragSamples: [(t: CFTimeInterval, dx: CGFloat, dy: CGFloat)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        spriteLayer.contentsGravity = .resizeAspect
        spriteLayer.magnificationFilter = .linear
        spriteLayer.frame = bounds
        spriteLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(spriteLayer)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func show(frame: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.contents = frame
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        dragged = false
        dragSamples.removeAll()
    }

    override func mouseDragged(with event: NSEvent) {
        dragged = true
        guard let window = window else { return }
        var origin = window.frame.origin
        origin.x += event.deltaX
        origin.y -= event.deltaY
        window.setFrameOrigin(origin)
        dragSamples.append((CACurrentMediaTime(), event.deltaX, -event.deltaY))
        if dragSamples.count > 8 { dragSamples.removeFirst() }
        onDrag?(event.deltaX)
    }

    override func mouseUp(with event: NSEvent) {
        if dragged {
            onDragEnd?(releaseVelocity())
        } else {
            onClick?()
        }
        dragged = false
        dragSamples.removeAll()
    }

    /// Velocity from samples within the last 0.12s before release.
    private func releaseVelocity() -> CGVector {
        let now = CACurrentMediaTime()
        let recent = dragSamples.filter { now - $0.t < 0.12 }
        guard let first = recent.first, recent.count >= 2 else { return .zero }
        let dt = now - first.t
        guard dt > 0.005 else { return .zero }
        let dx = recent.reduce(0) { $0 + $1.dx }
        let dy = recent.reduce(0) { $0 + $1.dy }
        return CGVector(dx: dx / dt, dy: dy / dt)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// Drives animation playback, autonomous behaviors, and the pet window.
final class PetController: NSObject {
    private let sheet: SpriteSheet
    private let window: NSWindow
    private let view: PetView

    private var state: PetState = .idle
    private var frameIndex = 0
    private var frameTimer: Timer?

    /// One-shot actions return to idle after N loops.
    private var loopsRemaining = 0
    private var behaviorTimer: Timer?
    private var walkTimer: Timer?
    private var walkDirection: CGFloat = 1
    private var randomBehaviorEnabled = true

    // Speech + reminders
    private var bubble: SpeechBubble?
    private let reminderCenter = ReminderCenter()
    private var sleepy = false

    // Throw physics
    private var physicsTimer: Timer?
    private var throwVelocity = CGVector.zero
    private var maxImpactSpeed: CGFloat = 0
    private var isThrowing = false

    private static let petSize = NSSize(width: 154, height: 166)
    private static let throwSpeedThreshold: CGFloat = 550
    private static let gravity: CGFloat = -3000
    private static let floorBounce: CGFloat = 0.45
    private static let wallBounce: CGFloat = 0.6

    init?(sheet: SpriteSheet) {
        self.sheet = sheet
        let screen = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: screen.midX - Self.petSize.width / 2,
            y: screen.minY + 40
        )
        window = NSWindow(
            contentRect: NSRect(origin: origin, size: Self.petSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = false

        view = PetView(frame: NSRect(origin: .zero, size: Self.petSize))
        window.contentView = view
        super.init()

        view.onDrag = { [weak self] dx in self?.handleDrag(dx: dx) }
        view.onDragEnd = { [weak self] v in self?.handleDragEnd(velocity: v) }
        view.onClick = { [weak self] in self?.playOnce(.waving) }
        view.menuProvider = { [weak self] in self?.buildMenu() ?? NSMenu() }

        window.orderFrontRegardless()
        bubble = SpeechBubble(parent: window)
        reminderCenter.delegate = self
        reminderCenter.start()
        setState(.idle)
        scheduleRandomBehavior()
    }

    /// Show a speech bubble above the pet.
    func say(_ text: String, duration: TimeInterval = 4) {
        bubble?.say(text, duration: duration)
    }

    // MARK: - Animation playback

    private func setState(_ newState: PetState, loops: Int = 0) {
        state = newState
        frameIndex = 0
        loopsRemaining = loops
        stepFrame()
    }

    private func stepFrame() {
        frameTimer?.invalidate()
        let frames = sheet.frames(for: state)
        guard !frames.isEmpty else { return }
        if frameIndex >= frames.count {
            frameIndex = 0
            if loopsRemaining > 0 {
                loopsRemaining -= 1
                if loopsRemaining == 0 {
                    state = .idle
                }
            }
        }
        view.show(frame: frames[frameIndex])
        var ms = Double(state.durations[frameIndex])
        if sleepy && state == .idle { ms *= 2.5 } // drowsy slow-motion idle
        frameIndex += 1
        frameTimer = Timer.scheduledTimer(
            withTimeInterval: ms / 1000.0, repeats: false
        ) { [weak self] _ in
            self?.stepFrame()
        }
    }

    /// Play a one-shot action for `loops` cycles, then return to idle.
    private func playOnce(_ action: PetState, loops: Int = 2) {
        stopWalk()
        setState(action, loops: loops)
    }

    // MARK: - Dragging

    private func handleDrag(dx: CGFloat) {
        stopWalk()
        stopThrow()
        let target: PetState = dx >= 0 ? .runningRight : .runningLeft
        if state != target {
            setState(target)
        }
    }

    private func handleDragEnd(velocity: CGVector) {
        let speed = hypot(velocity.dx, velocity.dy)
        if speed > Self.throwSpeedThreshold {
            startThrow(velocity: velocity)
        } else {
            setState(.jumping, loops: 1)
        }
    }

    // MARK: - Throw physics

    private func startThrow(velocity: CGVector) {
        stopWalk()
        frameTimer?.invalidate()
        isThrowing = true
        throwVelocity = velocity
        maxImpactSpeed = 0
        physicsTimer?.invalidate()
        physicsTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0 / 60.0, repeats: true
        ) { [weak self] _ in
            self?.stepPhysics()
        }
    }

    private func stepPhysics() {
        let dt: CGFloat = 1.0 / 60.0
        throwVelocity.dy += Self.gravity * dt
        var origin = window.frame.origin
        origin.x += throwVelocity.dx * dt
        origin.y += throwVelocity.dy * dt

        let screen = window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let floor = screen.minY
        var landed = false

        // Walls
        if origin.x < screen.minX {
            origin.x = screen.minX
            throwVelocity.dx = abs(throwVelocity.dx) * Self.wallBounce
        } else if origin.x + Self.petSize.width > screen.maxX {
            origin.x = screen.maxX - Self.petSize.width
            throwVelocity.dx = -abs(throwVelocity.dx) * Self.wallBounce
        }
        // Ceiling
        if origin.y + Self.petSize.height > screen.maxY {
            origin.y = screen.maxY - Self.petSize.height
            throwVelocity.dy = -abs(throwVelocity.dy) * Self.wallBounce
        }
        // Floor
        if origin.y <= floor {
            origin.y = floor
            let impact = abs(throwVelocity.dy)
            maxImpactSpeed = max(maxImpactSpeed, impact)
            throwVelocity.dy = impact * Self.floorBounce
            throwVelocity.dx *= 0.8
            if throwVelocity.dy < 220 && abs(throwVelocity.dx) < 60 {
                landed = true
            }
        }

        window.setFrameOrigin(origin)

        // Airborne frames: jumping row (1 = rising, 3 = falling, 2 = apex)
        let frames = sheet.frames(for: .jumping)
        if frames.count >= 5 {
            let idx: Int
            if throwVelocity.dy > 80 { idx = 1 }
            else if throwVelocity.dy < -80 { idx = 3 }
            else { idx = 2 }
            view.show(frame: frames[idx])
        }

        if landed { finishThrow() }
    }

    private func finishThrow() {
        stopThrow()
        if maxImpactSpeed > 1600 {
            say("请轻拿轻放一二大王！", duration: 3)
            setState(.failed, loops: 1)
        } else {
            setState(.jumping, loops: 1)
        }
    }

    private func stopThrow() {
        physicsTimer?.invalidate()
        physicsTimer = nil
        isThrowing = false
    }

    // MARK: - Autonomous behavior

    private func scheduleRandomBehavior() {
        behaviorTimer?.invalidate()
        let delay = Double.random(in: 7...15)
        behaviorTimer = Timer.scheduledTimer(
            withTimeInterval: delay, repeats: false
        ) { [weak self] _ in
            self?.performRandomBehavior()
            self?.scheduleRandomBehavior()
        }
    }

    private func performRandomBehavior() {
        guard randomBehaviorEnabled, state == .idle, !isThrowing else { return }
        let dice = Int.random(in: 0..<10)
        switch dice {
        case 0...3: startWalk()
        case 4: playOnce(.waving)
        case 5: playOnce(.jumping)
        case 6: playOnce(.waiting)
        case 7: playOnce(.review)
        case 8: playOnce(.running)
        default: break // stay idle
        }
    }

    private func startWalk() {
        stopWalk()
        walkDirection = Bool.random() ? 1 : -1
        setState(walkDirection > 0 ? .runningRight : .runningLeft)
        let duration = Double.random(in: 2...4)
        let deadline = Date().addingTimeInterval(duration)
        walkTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0 / 60.0, repeats: true
        ) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            var origin = self.window.frame.origin
            origin.x += self.walkDirection * 1.4
            if let screen = self.window.screen?.visibleFrame {
                if origin.x < screen.minX {
                    origin.x = screen.minX
                    self.walkDirection = 1
                    self.setState(.runningRight)
                } else if origin.x + Self.petSize.width > screen.maxX {
                    origin.x = screen.maxX - Self.petSize.width
                    self.walkDirection = -1
                    self.setState(.runningLeft)
                }
            }
            self.window.setFrameOrigin(origin)
            if Date() >= deadline {
                timer.invalidate()
                self.walkTimer = nil
                self.setState(.idle)
            }
        }
    }

    private func stopWalk() {
        walkTimer?.invalidate()
        walkTimer = nil
    }

    /// Walk to a target x position (window origin), then run completion.
    private func walkTo(x targetX: CGFloat, completion: @escaping () -> Void) {
        stopWalk()
        let currentX = window.frame.origin.x
        if abs(targetX - currentX) < 8 {
            completion()
            return
        }
        walkDirection = targetX > currentX ? 1 : -1
        setState(walkDirection > 0 ? .runningRight : .runningLeft)
        walkTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0 / 60.0, repeats: true
        ) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            var origin = self.window.frame.origin
            origin.x += self.walkDirection * 2.2
            let arrived = (self.walkDirection > 0 && origin.x >= targetX)
                || (self.walkDirection < 0 && origin.x <= targetX)
            if arrived { origin.x = targetX }
            self.window.setFrameOrigin(origin)
            if arrived {
                timer.invalidate()
                self.walkTimer = nil
                completion()
            }
        }
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let stateMenu = NSMenu()
        for petState in PetState.allCases {
            let item = NSMenuItem(
                title: petState.displayName,
                action: #selector(menuSelectState(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = petState.rawValue
            item.state = petState == state ? .on : .off
            stateMenu.addItem(item)
        }
        let stateItem = NSMenuItem(title: "动作", action: nil, keyEquivalent: "")
        menu.addItem(stateItem)
        menu.setSubmenu(stateMenu, for: stateItem)

        let randomItem = NSMenuItem(
            title: randomBehaviorEnabled ? "暂停随机行为" : "开启随机行为",
            action: #selector(menuToggleRandom),
            keyEquivalent: ""
        )
        randomItem.target = self
        menu.addItem(randomItem)

        // Reminder toggles
        let reminderMenu = NSMenu()
        for kind in ReminderKind.allCases {
            let item = NSMenuItem(
                title: kind.title,
                action: #selector(menuToggleReminder(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = kind.rawValue
            item.state = reminderCenter.isEnabled(kind) ? .on : .off
            reminderMenu.addItem(item)
        }
        let reminderItem = NSMenuItem(
            title: "提醒设置", action: nil, keyEquivalent: "")
        menu.addItem(reminderItem)
        menu.setSubmenu(reminderMenu, for: reminderItem)

        // Hidden test menu: hold Option while right-clicking
        if NSEvent.modifierFlags.contains(.option) {
            let testMenu = NSMenu()
            for kind in ReminderKind.allCases {
                let item = NSMenuItem(
                    title: "触发" + kind.title,
                    action: #selector(menuTestReminder(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = kind.rawValue
                testMenu.addItem(item)
            }
            let testItem = NSMenuItem(
                title: "测试提醒", action: nil, keyEquivalent: "")
            menu.addItem(testItem)
            menu.setSubmenu(testMenu, for: testItem)
        }

        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "退出", action: #selector(menuQuit), keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    @objc private func menuSelectState(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let petState = PetState(rawValue: raw) else { return }
        stopWalk()
        if petState == .idle || petState == .runningRight || petState == .runningLeft {
            setState(petState)
        } else {
            setState(petState, loops: 3)
        }
    }

    @objc private func menuToggleRandom() {
        randomBehaviorEnabled.toggle()
    }

    @objc private func menuToggleReminder(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let kind = ReminderKind(rawValue: raw) else { return }
        reminderCenter.setEnabled(kind, !reminderCenter.isEnabled(kind))
    }

    @objc private func menuTestReminder(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let kind = ReminderKind(rawValue: raw) else { return }
        reminderCenter.fire(kind)
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }
}

// MARK: - ReminderCenterDelegate

extension PetController: ReminderCenterDelegate {
    func reminderCenter(
        _ center: ReminderCenter, fire kind: ReminderKind, message: String
    ) {
        guard !isThrowing else { return }
        stopWalk()
        say(message, duration: 6)
        switch kind {
        case .sedentary:
            // Walk to the bottom-center of the screen, then jump to block you.
            let screen = window.screen?.visibleFrame
                ?? NSScreen.main?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let targetX = screen.midX - Self.petSize.width / 2
            walkTo(x: targetX) { [weak self] in
                self?.setState(.jumping, loops: 3)
            }
        case .water:
            playOnce(.waiting, loops: 3)
        case .lateNight:
            playOnce(.review, loops: 3)
        case .slacking:
            playOnce(.review, loops: 5)
        }
    }

    func reminderCenter(_ center: ReminderCenter, sleepyChanged sleepy: Bool) {
        self.sleepy = sleepy
        if sleepy {
            say("夜深了……我先眨一会儿眼睛 zzZ", duration: 5)
        }
    }
}
