import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showForceMaxConfirm = false
    @State private var eqImportAlert: EqImportAlert?
    @State private var eqDeleteAlert: EqDeleteAlert?
    @State private var showEqDetails: Bool = false

    private struct EqImportAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let collisionName: String?
        let pendingURL: URL?
    }

    private struct EqDeleteAlert: Identifiable {
        let id = UUID()
        let presetName: String
        let affectedDeviceUIDs: [String]
    }

    var body: some View {
        VStack(spacing: 0) {
            supportRow
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 4)
            Form {
                audioSection
                deviceSettingsSection
                notificationsSection
                appearanceSection
                upcomingProgramSection
                updatesSection
                accountSection
                dataSection
            }
            .formStyle(.grouped)
        }
        .frame(width: 480, height: 560)
        .task { await viewModel.start() }
        .alert("Force Max Volume", isPresented: $showForceMaxConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Continue", role: .destructive) {
                Task { await viewModel.setVolumeMode(.forceMax) }
            }
        } message: {
            Text(
                "This sets the macOS output volume for the selected device to 100% and removes software volume from the signal path. Lower the volume on your DAC, amp, or headphones first to avoid hearing damage."
            )
        }
        .alert(item: $eqImportAlert) { alert in
            if alert.collisionName != nil, let url = alert.pendingURL {
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .destructive(Text("Overwrite")) {
                        Task { await runEqImport(url: url, overwrite: true) }
                    },
                    secondaryButton: .cancel()
                )
            } else {
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
        .alert(item: $eqDeleteAlert) { alert in
            let count = alert.affectedDeviceUIDs.count
            let body =
                count == 0
                ? "Delete preset \u{201C}\(alert.presetName)\u{201D}?"
                : "Preset \u{201C}\(alert.presetName)\u{201D} is in use by \(count) device\(count == 1 ? "" : "s"). Deleting it will clear that reference."
            return Alert(
                title: Text("Delete preset?"),
                message: Text(body),
                primaryButton: .destructive(Text("Delete")) {
                    Task { try? await viewModel.deletePresetConfirmed(name: alert.presetName) }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var supportRow: some View {
        HStack(spacing: 10) {
            supportButton(
                title: "Support Radio Paradise",
                subtitle: "radioparadise.com",
                url: "https://radioparadise.com/donate",
                icon: AnyView(
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.pink)
                )
            )
            supportButton(
                title: "Buy Dev a coffee",
                subtitle: "buymeacoffee.com",
                url: "https://buymeacoffee.com/gvajda",
                icon: AnyView(bmcIcon)
            )
        }
    }

    private var bmcIcon: some View {
        let image: NSImage = {
            if let url = AppResources.bundle.url(forResource: "bmc", withExtension: "png"),
                let img = NSImage(contentsOf: url)
            {
                return img
            }
            return NSImage()
        }()
        return Image(nsImage: image)
            .resizable()
            .frame(width: 18, height: 18)
    }

    private func supportButton(title: String, subtitle: String, url: String, icon: AnyView)
        -> some View
    {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 8) {
                icon
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(SupportButtonStyle())
    }

    private var audioSection: some View {
        Section("Audio") {
            HStack {
                Picker("Output device", selection: deviceBinding) {
                    Text("Select an output device").tag(String?.none)
                    ForEach(viewModel.devices, id: \.uid) { device in
                        Text(deviceLabel(device)).tag(Optional(device.uid))
                    }
                }
                Button {
                    Task { await viewModel.refreshDevices() }
                } label: {
                    Image(systemName: "arrow.clockwise.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Rescan audio devices")
            }
        }
    }

    private var volumeRow: some View {
        HStack(spacing: 8) {
            Text("Volume")
            HoverInfoIcon(text: volumeTooltip)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                volumeButton(.none, label: "Default")
                volumeButton(.replayGain, label: "ReplayGain")
                volumeForceMaxButton
            }
        }
    }

    private func volumeButton(_ mode: VolumeMode, label: String) -> some View {
        Button {
            Task { await viewModel.setVolumeMode(mode) }
        } label: {
            Text(label).frame(minWidth: 72)
        }
        .buttonStyle(StableButtonStyle(filled: viewModel.volumeMode == mode))
    }

    private var volumeForceMaxButton: some View {
        Button {
            if viewModel.volumeMode != .forceMax {
                showForceMaxConfirm = true
            }
        } label: {
            Text("Force Max").frame(minWidth: 72)
        }
        .buttonStyle(StableButtonStyle(filled: viewModel.volumeMode == .forceMax))
        .disabled(!viewModel.hogModeEnabled)
    }

    private var volumeTooltip: String {
        "Default:\nNo loudness processing and no volume pinning. The audio signal is passed through unchanged; the macOS output slider controls the level.\n\nReplayGain:\nApplies per-track loudness normalization metadata embedded by Radio Paradise. Reduces peaks; small variation track-to-track.\n\nForce-Max Volume:\nOnly available in Hog mode, designed to use with external DACs with on-device volume control.\nPins device to max volume + caps mpv at 100. Hearing damage warning. Bit-perfect when EQ is off."
    }

    private var deviceSettingsSectionTitle: String {
        viewModel.currentDeviceName.map { "Output device settings — \($0)" }
            ?? "Output device settings"
    }

    private var deviceSettingsSection: some View {
        Section(deviceSettingsSectionTitle) {
            Picker("Bitrate", selection: bitrateBinding) {
                Text("32K AAC").tag(0)
                Text("64K AAC").tag(1)
                Text("128K AAC").tag(2)
                Text("128K MP3").tag(5)
                Text("320K AAC").tag(3)
                Text("320K MP3").tag(6)
                Text("FLAC").tag(4)
            }
            Toggle("Hog mode", isOn: hogModeBinding)
            Toggle("Release on Pause", isOn: releaseHogOnPauseBinding)
                .padding(.leading, 20)
                .disabled(!viewModel.hogModeEnabled)
            volumeRow
            eqSection
            crossfeedSection
        }
    }

    private var eqSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Equalizer")
                HoverInfoIcon(text: eqTooltip)
                if viewModel.eqEnabled {
                    Spacer(minLength: 8)
                    Picker(
                        "",
                        selection: Binding<String?>(
                            get: { viewModel.eqPresetName },
                            set: { v in Task { await viewModel.setEqPresetName(v) } }
                        )
                    ) {
                        Text("None (Bypass)").tag(String?.none)
                        ForEach(viewModel.availablePresets, id: \.self) { name in
                            Text(name).tag(Optional(name))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180)

                    Button {
                        guard let name = viewModel.eqPresetName else { return }
                        showEqDeleteConfirm(presetName: name)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(viewModel.eqPresetName == nil)
                    .help("Delete selected preset")

                    Button {
                        showEqDetails.toggle()
                    } label: {
                        Image(systemName: showEqDetails ? "eye.fill" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .disabled(viewModel.parsedEqPreset == nil)
                    .help("Show parsed preset values")

                    Button {
                        showEqImportPanel()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderless)
                    .help("Import preset (.txt)")

                    Button {
                        showEqExportPanel()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled(viewModel.eqPresetName == nil)
                    .help("Export selected preset")
                } else {
                    Spacer(minLength: 8)
                }
                Toggle(
                    "",
                    isOn: Binding(
                        get: { viewModel.eqEnabled },
                        set: { v in Task { await viewModel.setEqEnabled(v) } }
                    )
                )
                .labelsHidden()
            }
            if viewModel.eqEnabled, showEqDetails, let preset = viewModel.parsedEqPreset {
                eqDetailsView(preset: preset)
            }
        }
        .onAppear {
            Task {
                await viewModel.refreshPresets()
                await viewModel.reloadParsedPreset()
            }
        }
    }

    @ViewBuilder
    private func eqDetailsView(preset: EqPreset) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "Preamp · %+.1f dB", preset.preampDb))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            ForEach(Array(preset.bands.enumerated()), id: \.offset) { _, band in
                Text(eqBandLine(band))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.leading, 4)
        .padding(.top, 2)
    }

    private func eqBandLine(_ band: EqBand) -> String {
        let type: String
        switch band.type {
        case .peak: type = "PK"
        case .lowShelf: type = "LS"
        case .highShelf: type = "HS"
        }
        let freq: String
        if band.fcHz >= 1000 {
            freq = String(format: "%.2f kHz", band.fcHz / 1000.0)
        } else {
            freq = String(format: "%.0f Hz", band.fcHz)
        }
        return String(format: "%@ · %@ · Q %.2f · %+.1f dB", type, freq, band.q, band.gainDb)
    }

    private var eqTooltip: String {
        "Parametric EQ applied via libmpv (lavfi: volume + equalizer + lowshelf + highshelf).\n\nImport AutoEQ / Equalizer APO / REW .txt presets. Strict parser — files with unsupported filter types, malformed lines, or more than 10 bands are rejected.\n\nCreate presets at https://squig.link"
    }

    private var crossfeedSection: some View {
        HStack(spacing: 8) {
            Text("Crossfeed")
                .lineLimit(1)
                .fixedSize()
            HoverInfoIcon(text: crossfeedTooltip)
            if viewModel.crossfeedEnabled {
                Spacer(minLength: 8)

                Text("Strength")
                ClampedNumericField(
                    value: Binding(
                        get: { viewModel.crossfeedStrength },
                        set: { v in Task { await viewModel.setCrossfeedStrength(v) } }
                    ),
                    range: 0.0...1.0,
                    step: 0.05,
                    isEnabled: true
                )

                Text("Range")
                ClampedNumericField(
                    value: Binding(
                        get: { viewModel.crossfeedRange },
                        set: { v in Task { await viewModel.setCrossfeedRange(v) } }
                    ),
                    range: 0.0...1.0,
                    step: 0.05,
                    isEnabled: true
                )
            } else {
                Spacer(minLength: 8)
            }
            Toggle(
                "",
                isOn: Binding(
                    get: { viewModel.crossfeedEnabled },
                    set: { v in Task { await viewModel.setCrossfeedEnabled(v) } }
                )
            )
            .labelsHidden()
        }
    }

    private var crossfeedTooltip: String {
        """
        Crossfeed simulates a small amount of acoustic leakage between the left and right channels — only useful for headphones, where hard-panned stereo can feel unnaturally separated. Bauer-style implementation (BS2B).

        Strength (0.0–1.0): feed level — how much signal crosses to the opposite ear at low frequencies. Default 0.15 (~4.5 dB). Higher = stronger spatial blend.

        Range (0.0–1.0): cut frequency — upper bound of the crossfeed band, approx (1 − range) × 2100 Hz. Default 0.67 (~700 Hz cut, classical BS2B). Lower range = wider band.

        BS2B preset equivalents:
          Default   (700 Hz, 4.5 dB) → str 0.15, rng 0.67
          Chu Moy   (700 Hz, 6.0 dB) → str 0.22, rng 0.67
          Jan Meier (650 Hz, 9.5 dB) → str 0.45, rng 0.69
        """
    }

    private func showEqImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await runEqImport(url: url, overwrite: false) }
    }

    private func runEqImport(url: URL, overwrite: Bool) async {
        do {
            let outcome = try await viewModel.importPresetFile(url: url, overwrite: overwrite)
            switch outcome {
            case .imported(let name):
                await viewModel.setEqPresetName(name)
            case .nameCollision(let name):
                await MainActor.run {
                    eqImportAlert = EqImportAlert(
                        title: "Preset \u{201C}\(name)\u{201D} already exists",
                        message: "Overwrite the existing preset?",
                        collisionName: name,
                        pendingURL: url
                    )
                }
            }
        } catch SettingsViewModel.EqImportError.parseFailed(let reasons) {
            await MainActor.run {
                eqImportAlert = EqImportAlert(
                    title: "Cannot import preset",
                    message: reasons.joined(separator: "\n"),
                    collisionName: nil,
                    pendingURL: nil
                )
            }
        } catch {
            await MainActor.run {
                eqImportAlert = EqImportAlert(
                    title: "Cannot import preset",
                    message: "\(error)",
                    collisionName: nil,
                    pendingURL: nil
                )
            }
        }
    }

    private func showEqExportPanel() {
        guard let name = viewModel.eqPresetName else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(name).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { try await viewModel.exportPreset(to: url) } catch {
                await MainActor.run {
                    eqImportAlert = EqImportAlert(
                        title: "Export failed",
                        message: "\(error)",
                        collisionName: nil,
                        pendingURL: nil
                    )
                }
            }
        }
    }

    private func showEqDeleteConfirm(presetName: String) {
        Task {
            let uids = await viewModel.prepareDeletePreset(name: presetName)
            await MainActor.run {
                eqDeleteAlert = EqDeleteAlert(presetName: presetName, affectedDeviceUIDs: uids)
            }
        }
    }

    private var notificationsSection: some View {
        Section("Notifications") {
            Toggle("Show desktop notifications on song start", isOn: notificationsBinding)
        }
    }

    private var updatesSection: some View {
        Section("Updates") {
            Toggle("Check for updates automatically", isOn: updateCheckEnabledBinding)
            Text("Daily, while the app is running.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline) {
                if viewModel.updateAvailable {
                    Button("Open Update…") {
                        Task { await viewModel.openUpdate() }
                    }
                } else {
                    Button("Check Now") {
                        Task { await viewModel.checkNow() }
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Last checked: \(viewModel.lastCheckedRelative)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(viewModel.currentVersionLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            HStack {
                Text("Appearance")
                Spacer()
                HStack(spacing: 6) {
                    appearanceButton(.system, label: "System")
                    appearanceButton(.light, label: "Light")
                    appearanceButton(.dark, label: "Dark")
                }
            }
            HStack {
                Text("Menu bar icon")
                Spacer()
                HStack(spacing: 6) {
                    menuBarIconButton(.template, label: "White")
                    menuBarIconButton(.color, label: "Color")
                }
            }
            HStack {
                Text("Popover style")
                Spacer()
                HStack(spacing: 6) {
                    popoverStyleButton(.none, label: "None")
                    popoverStyleButton(.ambient, label: "Ambient")
                    popoverStyleButton(.frosty, label: "Frosty")
                }
            }
            Toggle("Frosted Upcoming Program window", isOn: frostedUpcomingBinding)
        }
    }

    private func popoverStyleButton(_ style: PopoverStyle, label: String) -> some View {
        Button {
            Task { await viewModel.setPopoverStyle(style) }
        } label: {
            Text(label).frame(minWidth: 56)
        }
        .buttonStyle(StableButtonStyle(filled: viewModel.popoverStyle == style))
    }

    private func menuBarIconButton(_ style: MenuBarIconStyle, label: String) -> some View {
        Button {
            Task { await viewModel.setMenuBarIconStyle(style) }
        } label: {
            Text(label).frame(minWidth: 56)
        }
        .buttonStyle(StableButtonStyle(filled: viewModel.menuBarIconStyle == style))
    }

    private func appearanceButton(_ mode: AppearanceMode, label: String) -> some View {
        Button {
            Task { await viewModel.setAppearance(mode) }
        } label: {
            Text(label).frame(minWidth: 56)
        }
        .buttonStyle(StableButtonStyle(filled: viewModel.appearance == mode))
    }

    private var upcomingProgramSection: some View {
        Section("Upcoming Program") {
            Stepper(
                "Rows: \(viewModel.upcomingRowCount)",
                value: Binding(
                    get: { viewModel.upcomingRowCount },
                    set: { v in Task { await viewModel.setUpcomingRowCount(v) } }
                ),
                in: 3...10)
            if !viewModel.upcomingChannels.isEmpty {
                ForEach(viewModel.upcomingChannels, id: \.chan) { channel in
                    let chanId = Int(channel.chan) ?? -1
                    Toggle(
                        channel.title,
                        isOn: Binding(
                            get: { !viewModel.upcomingHiddenChannelIds.contains(chanId) },
                            set: { visible in
                                Task { await viewModel.setChannelHidden(chanId, !visible) }
                            }
                        )
                    )
                }
            }
        }
    }

    private var accountSection: some View {
        Section("Account") {
            HStack {
                if viewModel.isSignedIn {
                    if let username = viewModel.currentUsername {
                        Text("Signed in as ") + Text(username).bold()
                    } else {
                        Text("Signed in")
                    }
                } else {
                    Text("Anonymous")
                }
                Spacer()
                if viewModel.isSignedIn {
                    Button("Sign out") {
                        Task { await viewModel.signOut() }
                    }
                    .buttonStyle(StableButtonStyle())
                } else {
                    Button("Sign in") { viewModel.openLoginWindow() }
                        .buttonStyle(StableButtonStyle())
                }
            }
        }
    }

    private var dataSection: some View {
        Section("Data") {
            HStack {
                Button("Show application data") { viewModel.openApplicationData() }
                    .buttonStyle(StableButtonStyle())
                Spacer()
            }
            Toggle("Verbose logging", isOn: verboseLoggingBinding)
        }
    }

    private func deviceLabel(_ device: AudioDevice) -> String {
        let suffix =
            device.transportType.isBitPerfectRecommended ? "" : " (not recommended for bit-perfect)"
        return "\(device.name) — \(device.transportType.label)\(suffix)"
    }

    private var deviceBinding: Binding<String?> {
        Binding(
            get: { viewModel.outputDeviceUID },
            set: { newValue in Task { await viewModel.setOutputDeviceUID(newValue) } }
        )
    }

    private var hogModeBinding: Binding<Bool> {
        Binding(
            get: { viewModel.hogModeEnabled },
            set: { newValue in Task { await viewModel.setHogModeEnabled(newValue) } }
        )
    }

    private var releaseHogOnPauseBinding: Binding<Bool> {
        Binding(
            get: { viewModel.releaseHogOnPauseEnabled },
            set: { newValue in Task { await viewModel.setReleaseHogOnPauseEnabled(newValue) } }
        )
    }

    private var notificationsBinding: Binding<Bool> {
        Binding(
            get: { viewModel.notificationsEnabled },
            set: { newValue in Task { await viewModel.setNotificationsEnabled(newValue) } }
        )
    }

    private var updateCheckEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.updateCheckEnabled },
            set: { value in Task { await viewModel.setUpdateCheckEnabled(value) } }
        )
    }

    private var appearanceBinding: Binding<AppearanceMode> {
        Binding(
            get: { viewModel.appearance },
            set: { newValue in Task { await viewModel.setAppearance(newValue) } }
        )
    }

    private var frostedUpcomingBinding: Binding<Bool> {
        Binding(
            get: { viewModel.frostedUpcomingEnabled },
            set: { newValue in Task { await viewModel.setFrostedUpcomingEnabled(newValue) } }
        )
    }

    private var bitrateBinding: Binding<Int> {
        Binding(
            get: { viewModel.bitrate },
            set: { newValue in Task { await viewModel.setBitrate(newValue) } }
        )
    }

    private var verboseLoggingBinding: Binding<Bool> {
        Binding(
            get: { viewModel.verboseLoggingEnabled },
            set: { newValue in Task { await viewModel.setVerboseLoggingEnabled(newValue) } }
        )
    }
}
