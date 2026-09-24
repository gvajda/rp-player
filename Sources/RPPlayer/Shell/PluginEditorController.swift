import AppKit
import AVFAudio
import Combine
import CoreAudioKit

@MainActor
final class PluginEditorController: NSObject, NSWindowDelegate {
    private let host: PluginHost
    private var panel: NSPanel?
    private var unit: AVAudioUnit?
    private var currentSink: AnyCancellable?
    private var autosaveTimer: Timer?
    private var lastSavedState: Data?

    init(host: PluginHost) {
        self.host = host
        super.init()
    }

    func open() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        guard let plugin = host.current, let unit = host.audioUnit else { return }
        self.unit = unit
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "\(plugin.component.manufacturerName) \(plugin.component.name)"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        self.panel = panel
        // The host publishes current = nil before releasing the old unit; closing here keeps the view off a freed unit.
        currentSink = host.$current.dropFirst().sink { [weak self] _ in self?.close() }
        // Captured so install() can reject a stale completion after a close/reopen swapped self.unit.
        let requestedUnit = ObjectIdentifier(unit)
        unit.auAudioUnit.requestViewController { [weak self] controller in
            DispatchQueue.main.async { self?.install(controller, for: requestedUnit) }
        }
        lastSavedState = stateData()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autosave() }
        }
    }

    func close() {
        guard let panel else { return }
        panel.delegate = nil
        panel.close()
        teardown(save: true)
    }

    func windowWillClose(_ notification: Notification) {
        teardown(save: true)
    }

    private func install(_ controller: NSViewController?, for expected: ObjectIdentifier) {
        guard let panel, let unit, ObjectIdentifier(unit) == expected else { return }
        if let controller {
            panel.contentViewController = controller
            if controller.preferredContentSize != .zero { panel.setContentSize(controller.preferredContentSize) }
        } else {
            let generic = AUGenericView(audioUnit: unit.audioUnit)
            generic.showsExpertParameters = true
            panel.contentView = generic
            panel.setContentSize(generic.frame.size)
        }
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func autosave() {
        guard let data = stateData(), data != lastSavedState else { return }
        lastSavedState = data
        Task { await host.saveCurrentState() }
    }

    private func stateData() -> Data? {
        guard let state = unit?.auAudioUnit.fullState else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
    }

    private func teardown(save: Bool) {
        autosaveTimer?.invalidate()
        autosaveTimer = nil
        currentSink = nil
        let closingPanel = panel
        panel = nil
        // Detach the content before dropping our unit reference, so nothing on screen outlives it.
        closingPanel?.contentViewController = nil
        closingPanel?.contentView = nil
        unit = nil
        if save { Task { await host.saveCurrentState() } }
    }
}
