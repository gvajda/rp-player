import AppKit

@MainActor
final class HoverTooltipWindow {
    private let panel: NSPanel
    private let label: NSTextField
    private let container: NSView

    init() {
        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.backgroundColor = .clear
        label.drawsBackground = false

        container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.layer?.cornerRadius = 4
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor.separatorColor.cgColor
        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -3),
        ])

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 60, height: 20),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.contentView = container
    }

    func show(text: String, anchoredAt point: NSPoint) {
        update(text: text)
        positionBelow(point: point)
        panel.orderFront(nil)
    }

    func update(text: String) {
        label.stringValue = text
        let labelSize = label.intrinsicContentSize
        let panelSize = NSSize(width: ceil(labelSize.width) + 12, height: ceil(labelSize.height) + 6)
        let origin = panel.frame.origin
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
    }

    func reposition(anchoredAt point: NSPoint) {
        positionBelow(point: point)
    }

    func hide() {
        panel.orderOut(nil)
    }

    // The cursor hotspot is the given point; the arrow extends ~16pt down-right.
    // Offset the panel below the arrow so it doesn't sit under the cursor.
    private func positionBelow(point: NSPoint) {
        let panelSize = panel.frame.size
        let x = point.x - panelSize.width / 2
        let y = point.y - panelSize.height - 20
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

@MainActor
final class HoverTracker: NSResponder {
    private let onEnter: () -> Void
    private let onExit: () -> Void

    init(onEnter: @escaping () -> Void, onExit: @escaping () -> Void) {
        self.onEnter = onEnter
        self.onExit = onExit
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func mouseEntered(with event: NSEvent) { onEnter() }
    override func mouseExited(with event: NSEvent) { onExit() }
}
