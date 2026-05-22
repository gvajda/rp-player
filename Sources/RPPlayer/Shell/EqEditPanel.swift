import SwiftUI

struct EqEditPanel: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showSaveAsSheet = false
    @State private var showRenameSheet = false
    @State private var saveAsName = ""
    @State private var renameTarget = ""
    @State private var sheetError: String?
    @State private var saveAlert: String?
    @State private var sharedSaveConfirm: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let preset = viewModel.editingPreset {
                footer(preset)
                header(preset)
                Divider()
                preampRow(preset)
                bandsGrid(preset)
                Button {
                    Task { await viewModel.addEditingBand() }
                } label: {
                    Label("Add band", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(preset.bands.count >= 10)
            }
        }
        .padding(.top, 4)
        .padding(.leading, 4)
        .sheet(isPresented: $showSaveAsSheet) {
            nameSheet(
                title: "Save preset as",
                initialValue: saveAsName,
                onConfirm: { name in
                    do {
                        try await viewModel.saveEditAs(name: name)
                        showSaveAsSheet = false
                    } catch EqPresetStoreError.alreadyExists {
                        sheetError = "Name already used. Pick another."
                    } catch EqPresetStoreError.invalidName {
                        sheetError = "Use 1–30 characters; no slashes or leading dot."
                    } catch {
                        sheetError = nil
                        saveAlert = "Failed to save preset: \(error)"
                        showSaveAsSheet = false
                    }
                }
            )
        }
        .sheet(isPresented: $showRenameSheet) {
            nameSheet(
                title: "Rename preset",
                initialValue: renameTarget,
                onConfirm: { name in
                    guard let from = viewModel.editingOriginalName else {
                        showRenameSheet = false
                        return
                    }
                    do {
                        try await viewModel.renamePreset(from: from, to: name)
                        showRenameSheet = false
                    } catch EqPresetStoreError.alreadyExists {
                        sheetError = "Name already used. Pick another."
                    } catch EqPresetStoreError.invalidName {
                        sheetError = "Use 1–30 characters; no slashes or leading dot."
                    } catch {
                        sheetError = nil
                        saveAlert = "Failed to rename preset: \(error)"
                        showRenameSheet = false
                    }
                }
            )
        }
        .alert("Save failed", isPresented: Binding(get: { saveAlert != nil }, set: { if !$0 { saveAlert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveAlert ?? "")
        }
        .alert("Save shared preset?", isPresented: Binding(
            get: { sharedSaveConfirm != nil },
            set: { if !$0 { sharedSaveConfirm = nil } }
        )) {
            Button("Cancel", role: .cancel) { sharedSaveConfirm = nil }
            Button("Save Anyway") {
                sharedSaveConfirm = nil
                Task {
                    do {
                        try await viewModel.saveEdit()
                    } catch {
                        saveAlert = "Failed to save preset: \(error)"
                    }
                }
            }
        } message: {
            if let n = sharedSaveConfirm {
                Text("This preset is used by \(n) audio devices. Saving will update it everywhere.")
            }
        }
    }

    private func header(_ preset: EqPreset) -> some View {
        HStack {
            Text("Editing: \(viewModel.editingOriginalName ?? "Untitled")")
                .font(.headline)
            if viewModel.editingDirty {
                Text("(unsaved)").foregroundStyle(.secondary).font(.caption)
            }
            Spacer()
        }
    }

    private func preampRow(_ preset: EqPreset) -> some View {
        HStack {
            Text("Preamp:")
            Stepper(
                value: Binding(
                    get: { preset.preampDb },
                    set: { v in Task { await viewModel.setEditingPreamp(v) } }
                ),
                in: -30...10,
                step: 0.1
            ) {
                Text(String(format: "%+.1f dB", preset.preampDb)).monospacedDigit()
            }
            .frame(maxWidth: 220)
        }
    }

    @ViewBuilder
    private func bandsGrid(_ preset: EqPreset) -> some View {
        if preset.bands.isEmpty {
            Text("No bands. Click + Add band to start.").foregroundStyle(.secondary).font(.caption)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Text("Type").font(.caption).foregroundStyle(.secondary)
                    Text("Frequency").font(.caption).foregroundStyle(.secondary)
                    Text("Gain").font(.caption).foregroundStyle(.secondary)
                    Text("Q").font(.caption).foregroundStyle(.secondary)
                    Color.clear.frame(width: 16, height: 1)
                }
                ForEach(Array(preset.bands.enumerated()), id: \.offset) { idx, band in
                    bandRow(idx: idx, band: band)
                }
            }
        }
    }

    private func bandRow(idx: Int, band: EqBand) -> some View {
        GridRow {
            Picker(
                "",
                selection: Binding(
                    get: { typeMenuValue(for: band) },
                    set: { newValue in
                        Task {
                            let updated = applyTypeMenu(newValue, to: band)
                            await viewModel.setEditingBand(at: idx, updated)
                        }
                    }
                )
            ) {
                Text("Bypass").tag(BandTypeMenu.bypass)
                Text("Peak").tag(BandTypeMenu.peak)
                Text("Low Shelf").tag(BandTypeMenu.lowShelf)
                Text("High Shelf").tag(BandTypeMenu.highShelf)
            }
            .labelsHidden()
            .frame(maxWidth: 130)

            Stepper(
                value: Binding(
                    get: { Double(Int(band.fcHz)) },
                    set: { v in
                        var b = band
                        b.fcHz = v
                        Task { await viewModel.setEditingBand(at: idx, b) }
                    }
                ),
                in: 20...20000,
                step: 1
            ) {
                Text(String(format: "%5.0f Hz", band.fcHz)).monospacedDigit()
            }
            .frame(maxWidth: 150)

            Stepper(
                value: Binding(
                    get: { band.gainDb },
                    set: { v in
                        var b = band
                        b.gainDb = v
                        Task { await viewModel.setEditingBand(at: idx, b) }
                    }
                ),
                in: -24...24,
                step: 0.1
            ) {
                Text(String(format: "%+5.1f dB", band.gainDb)).monospacedDigit()
            }
            .frame(maxWidth: 150)

            Stepper(
                value: Binding(
                    get: { band.q },
                    set: { v in
                        var b = band
                        b.q = v
                        Task { await viewModel.setEditingBand(at: idx, b) }
                    }
                ),
                in: 0.1...10.0,
                step: 0.1
            ) {
                Text(String(format: "%4.2f", band.q)).monospacedDigit()
            }
            .frame(maxWidth: 130)

            Button {
                Task { await viewModel.removeEditingBand(at: idx) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    private func footer(_ preset: EqPreset) -> some View {
        HStack {
            Button("Cancel") {
                Task { await viewModel.cancelEdit() }
            }
            Spacer()
            Button("Rename…") {
                renameTarget = viewModel.editingOriginalName ?? ""
                sheetError = nil
                showRenameSheet = true
            }
            .disabled(viewModel.editingIsNew)

            Button("Save As…") {
                saveAsName = viewModel.editingOriginalName.map { "\($0)-copy" } ?? "Untitled"
                sheetError = nil
                showSaveAsSheet = true
            }

            Button("Save") {
                Task {
                    guard let name = viewModel.editingOriginalName else { return }
                    let count = await viewModel.presetReferenceCount(name: name)
                    if count > 1 {
                        sharedSaveConfirm = count
                    } else {
                        do {
                            try await viewModel.saveEdit()
                        } catch {
                            saveAlert = "Failed to save preset: \(error)"
                        }
                    }
                }
            }
            .disabled(viewModel.editingIsNew || !viewModel.editingDirty)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func nameSheet(
        title: String,
        initialValue: String,
        onConfirm: @escaping @MainActor (String) async -> Void
    ) -> some View {
        let binding = Binding<String>(
            get: { saveAsName.isEmpty ? renameTarget : saveAsName },
            set: { v in
                let capped = String(v.prefix(30))
                if showSaveAsSheet { saveAsName = capped } else { renameTarget = capped }
            }
        )
        return VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Preset name", text: binding)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onAppear {
                    if showSaveAsSheet { saveAsName = initialValue }
                    else { renameTarget = initialValue }
                }
            if let err = sheetError {
                Text(err).foregroundStyle(.red).font(.caption)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    showSaveAsSheet = false
                    showRenameSheet = false
                    sheetError = nil
                }
                Button("OK") {
                    let name = showSaveAsSheet ? saveAsName : renameTarget
                    Task { await onConfirm(name) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled((showSaveAsSheet ? saveAsName : renameTarget).isEmpty)
            }
        }
        .padding(16)
    }

    private enum BandTypeMenu: Hashable { case bypass, peak, lowShelf, highShelf }

    private func typeMenuValue(for band: EqBand) -> BandTypeMenu {
        if !band.enabled { return .bypass }
        switch band.type {
        case .peak: return .peak
        case .lowShelf: return .lowShelf
        case .highShelf: return .highShelf
        }
    }

    private func applyTypeMenu(_ menu: BandTypeMenu, to band: EqBand) -> EqBand {
        var b = band
        switch menu {
        case .bypass:
            b.enabled = false
        case .peak:
            b.enabled = true
            b.type = .peak
        case .lowShelf:
            b.enabled = true
            b.type = .lowShelf
        case .highShelf:
            b.enabled = true
            b.type = .highShelf
        }
        return b
    }
}
