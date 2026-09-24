import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AudioUnitSection: View {
    @ObservedObject var model: AudioUnitSettingsModel
    @ObservedObject var host: PluginHost
    let editor: PluginEditorController
    @State private var importError: String?
    @State private var deleteTarget: ImportedPlugin?

    init(model: AudioUnitSettingsModel, editor: PluginEditorController) {
        self.model = model
        self.host = model.host
        self.editor = editor
    }

    private var usable: Bool { model.isBridgeAvailable && model.hasOutputDevice }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Audio Unit")
                HoverInfoIcon(text: tooltip)
                Spacer(minLength: 8)
                if model.pluginEnabled && usable {
                    picker
                    Button { editor.open() } label: { Image(systemName: "slider.horizontal.3") }
                        .buttonStyle(.borderless)
                        .disabled(host.current == nil)
                        .help("Open the plugin's controls")
                    Button { showImportPanel() } label: { Image(systemName: "square.and.arrow.down") }
                        .buttonStyle(.borderless)
                        .help("Import an Audio Unit (.component)")
                    Button { deleteTarget = model.plugins.first { $0.id == model.pluginId } } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .disabled(model.pluginId == nil)
                        .help("Delete the selected plugin")
                }
                Toggle("", isOn: Binding(get: { model.pluginEnabled && usable },
                                         set: { v in Task { await model.setEnabled(v) } }))
                    .labelsHidden()
                    .disabled(!usable)
            }
            if let note = disabledNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            } else if model.pluginEnabled, let error = host.loadError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await model.start() }
        .alert("Couldn't import plugin", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .alert(item: $deleteTarget) { plugin in
            Alert(title: Text("Delete \u{201C}\(plugin.component.name)\u{201D}?"),
                  message: Text("Every output device using it will play without a plugin."),
                  primaryButton: .destructive(Text("Delete")) {
                      Task {
                          do { try await model.deletePlugin(id: plugin.id) }
                          catch { importError = AudioUnitSettingsModel.message(for: error) }
                      }
                  },
                  secondaryButton: .cancel())
        }
    }

    private var picker: some View {
        Picker("", selection: Binding<String?>(get: { model.pluginId },
                                               set: { id in Task { await model.setPluginId(id) } })) {
            if model.plugins.isEmpty {
                Text("No plugins imported").tag(String?.none)
            } else {
                Text("None").tag(String?.none)
                ForEach(model.plugins) { plugin in
                    Text("\(plugin.component.name) — \(plugin.component.manufacturerName) v\(plugin.component.versionString)")
                        .tag(Optional(plugin.id))
                }
            }
        }
        .labelsHidden()
        .frame(maxWidth: 200)
    }

    private var disabledNote: String? {
        if !model.isBridgeAvailable { return "Audio Unit hosting is unavailable. See the log for details." }
        if !model.hasOutputDevice { return "Select an output device to use Audio Unit plugins." }
        return nil
    }

    private var tooltip: String {
        """
        Runs one Audio Unit effect (an AUv2 .component) on playback, after the equalizer and before crossfeed.

        Imported plugins are copied into RP Player's own folder and aren't visible to other apps. Self-contained plugins (for example Airwindows) work best; plugins that need iLok or a vendor installer may not load. A plugin that crashes will close RP Player.

        Bit-perfect is off while a plugin is active.
        """
    }

    private func showImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "component") ?? .bundle]
        panel.directoryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Audio/Plug-Ins/Components")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { try await model.importComponent(from: url) }
            catch { importError = AudioUnitSettingsModel.message(for: error) }
        }
    }
}
