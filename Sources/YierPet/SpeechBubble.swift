import AppKit

/// Draws the rounded bubble shape with a small tail pointing down.
/// The tail is part of one continuous outline so there is no seam.
final class BubbleView: NSView {
    static let tailHeight: CGFloat = 8

    override func draw(_ dirtyRect: NSRect) {
        let r: CGFloat = 10
        let tailW: CGFloat = 14
        let minX: CGFloat = 1
        let maxX = bounds.width - 1
        let minY = Self.tailHeight + 1
        let maxY = bounds.height - 1
        let midX = bounds.midX

        let path = NSBezierPath()
        // Start at tail left base, dip to the tip, back up to the right base.
        path.move(to: NSPoint(x: midX - tailW / 2, y: minY))
        path.line(to: NSPoint(x: midX, y: 1))
        path.line(to: NSPoint(x: midX + tailW / 2, y: minY))
        // Bottom edge -> bottom-right corner
        path.line(to: NSPoint(x: maxX - r, y: minY))
        path.appendArc(
            withCenter: NSPoint(x: maxX - r, y: minY + r), radius: r,
            startAngle: -90, endAngle: 0)
        // Right edge -> top-right corner
        path.line(to: NSPoint(x: maxX, y: maxY - r))
        path.appendArc(
            withCenter: NSPoint(x: maxX - r, y: maxY - r), radius: r,
            startAngle: 0, endAngle: 90)
        // Top edge -> top-left corner
        path.line(to: NSPoint(x: minX + r, y: maxY))
        path.appendArc(
            withCenter: NSPoint(x: minX + r, y: maxY - r), radius: r,
            startAngle: 90, endAngle: 180)
        // Left edge -> bottom-left corner
        path.line(to: NSPoint(x: minX, y: minY + r))
        path.appendArc(
            withCenter: NSPoint(x: minX + r, y: minY + r), radius: r,
            startAngle: 180, endAngle: 270)
        path.close()

        NSColor.white.withAlphaComponent(0.96).setFill()
        path.fill()
        NSColor(calibratedWhite: 0.72, alpha: 1).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// A speech bubble hosted in a child window above the pet window.
/// Being a child window, it follows the pet automatically during
/// walking, dragging, and throwing.
final class SpeechBubble {
    private let window: NSWindow
    private let bubbleView = BubbleView()
    private let label: NSTextField
    private weak var parentWindow: NSWindow?
    private var hideTimer: Timer?

    private static let maxTextWidth: CGFloat = 220
    private static let padding: CGFloat = 10
    /// The sprite cell has transparent headroom above the character,
    /// so the bubble overlaps the pet window top to sit near the head.
    private static let overlapIntoPet: CGFloat = 98

    init(parent: NSWindow) {
        parentWindow = parent
        label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor(calibratedWhite: 0.15, alpha: 1)
        label.alignment = .center
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = parent.level
        window.ignoresMouseEvents = true
        window.collectionBehavior = parent.collectionBehavior
        bubbleView.addSubview(label)
        window.contentView = bubbleView
        window.alphaValue = 0
        parent.addChildWindow(window, ordered: .above)
    }

    func say(_ text: String, duration: TimeInterval = 4) {
        guard let parent = parentWindow else { return }
        label.stringValue = text
        let textSize = label.sizeThatFits(
            NSSize(width: Self.maxTextWidth, height: 400)
        )
        let w = textSize.width + Self.padding * 2
        let h = textSize.height + Self.padding * 2 + BubbleView.tailHeight
        let pf = parent.frame
        window.setFrame(
            NSRect(
                x: pf.midX - w / 2,
                y: pf.maxY - Self.overlapIntoPet,
                width: w, height: h
            ),
            display: true
        )
        label.frame = NSRect(
            x: Self.padding,
            y: BubbleView.tailHeight + Self.padding,
            width: textSize.width,
            height: textSize.height
        )
        bubbleView.needsDisplay = true

        hideTimer?.invalidate()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            window.animator().alphaValue = 1
        }
        hideTimer = Timer.scheduledTimer(
            withTimeInterval: duration, repeats: false
        ) { [weak self] _ in
            self?.hide()
        }
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            window.animator().alphaValue = 0
        }
    }
}
