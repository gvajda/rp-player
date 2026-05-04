import AppKit

@MainActor
final class StatusItemController {
    let statusItem: NSStatusItem
    private let popover: PopoverController
    private let showHandler: (NSView) -> Void
    private let closeHandler: () -> Void
    private let menuProvider: (() -> NSMenu)?
    private let remainingSecondsProvider: (@MainActor () -> Int?)?

    private let tooltipWindow = HoverTooltipWindow()
    private var hoverTracker: HoverTracker?
    private var hoverTimer: Timer?
    private var showWorkItem: DispatchWorkItem?

    init(
        statusBar: NSStatusBar = .system,
        popover: PopoverController,
        menuProvider: (() -> NSMenu)? = nil,
        remainingSecondsProvider: (@MainActor () -> Int?)? = nil,
        show: ((NSView) -> Void)? = nil,
        close: (() -> Void)? = nil,
        initialIconStyle: MenuBarIconStyle = .template
    ) {
        let item = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        Self.applyIcon(initialIconStyle, to: item)
        item.button?.setAccessibilityLabel("RP Player")

        self.statusItem = item
        self.popover = popover
        self.menuProvider = menuProvider
        self.remainingSecondsProvider = remainingSecondsProvider
        self.showHandler = show ?? { anchor in popover.show(relativeTo: anchor) }
        self.closeHandler = close ?? { popover.close() }

        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.target = self
        item.button?.action = #selector(buttonClicked(_:))

        if let button = item.button {
            installHoverTracking(on: button)
        }
    }

    func setIconStyle(_ style: MenuBarIconStyle) {
        Self.applyIcon(style, to: statusItem)
    }

    private static func applyIcon(_ style: MenuBarIconStyle, to item: NSStatusItem) {
        let resourceName: String
        let isTemplate: Bool
        switch style {
        case .color:
            resourceName = "rp-color"
            isTemplate = false
        case .template:
            resourceName = "rp-template"
            isTemplate = true
        }
        if let url = Bundle.module.url(forResource: resourceName, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = isTemplate
            item.button?.image = image
        } else {
            let fallback = NSImage(systemSymbolName: "music.note", accessibilityDescription: "RP Player")
            fallback?.isTemplate = true
            item.button?.image = fallback
        }
    }

    func toggle() {
        if popover.isShown {
            closeHandler()
        } else if let button = statusItem.button {
            showHandler(button)
        }
    }

    func closeIfShown() {
        if popover.isShown {
            closeHandler()
        }
    }

    func showPopoverIfNeeded() {
        guard !popover.isShown, let button = statusItem.button else { return }
        showHandler(button)
    }

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        cancelHover()
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu(from: sender)
        } else {
            toggle()
        }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        guard let menu = menuProvider?() else { return }
        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    private func installHoverTracking(on button: NSStatusBarButton) {
        let tracker = HoverTracker(
            onEnter: { [weak self] in self?.handleHoverEnter() },
            onExit: { [weak self] in self?.handleHoverExit() }
        )
        self.hoverTracker = tracker
        let area = NSTrackingArea(
            rect: button.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: tracker,
            userInfo: nil
        )
        button.addTrackingArea(area)
    }

    private func handleHoverEnter() {
        showWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showTooltipNow() }
        showWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30, execute: work)
    }

    private func handleHoverExit() {
        cancelHover()
    }

    private func cancelHover() {
        showWorkItem?.cancel()
        showWorkItem = nil
        hoverTimer?.invalidate()
        hoverTimer = nil
        tooltipWindow.hide()
    }

    private func showTooltipNow() {
        guard let button = statusItem.button else { return }
        tooltipWindow.show(detail: currentDetailText(), below: button)
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let button = self.statusItem.button else { return }
                self.tooltipWindow.update(detail: self.currentDetailText())
                self.tooltipWindow.reposition(below: button)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func currentDetailText() -> String? {
        guard let secs = remainingSecondsProvider?() else { return nil }
        let s = max(0, secs)
        return String(format: "-%d:%02d", s / 60, s % 60)
    }
}
