import AppKit

@MainActor
final class HoverTooltipWindow {
    private let panel: NSPanel
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField
    private let stack: NSStackView
    private let container: NSView

    init() {
        titleLabel = NSTextField(labelWithString: "RP Player")
        titleLabel.font = .systemFont(ofSize: 11)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.backgroundColor = .clear
        titleLabel.drawsBackground = false

        detailLabel = NSTextField(labelWithString: "")
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .labelColor
        detailLabel.alignment = .center
        detailLabel.backgroundColor = .clear
        detailLabel.drawsBackground = false

        stack = NSStackView(views: [titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        container = AdaptiveBackgroundView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 4
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor.separatorColor.cgColor
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -3),
        ])

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 32),
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

    func show(detail: String?, below button: NSStatusBarButton) {
        update(detail: detail)
        repositionBelow(button)
        panel.orderFront(nil)
    }

    func update(detail: String?) {
        if let d = detail, !d.isEmpty {
            detailLabel.stringValue = d
            detailLabel.isHidden = false
        } else {
            detailLabel.isHidden = true
        }
        stack.layoutSubtreeIfNeeded()
        let stackSize = stack.fittingSize
        let panelSize = NSSize(width: ceil(stackSize.width) + 12, height: ceil(stackSize.height) + 6)
        let origin = panel.frame.origin
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
    }

    func reposition(below button: NSStatusBarButton) {
        repositionBelow(button)
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func repositionBelow(_ button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        let buttonInWindow = button.convert(button.bounds, to: nil)
        let buttonInScreen = buttonWindow.convertToScreen(buttonInWindow)
        let panelSize = panel.frame.size
        let x = buttonInScreen.midX - panelSize.width / 2
        let y = buttonInScreen.minY - panelSize.height - 4
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

private final class AdaptiveBackgroundView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
}
