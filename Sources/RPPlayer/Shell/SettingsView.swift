import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showForceMaxConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            supportRow
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 4)
            Form {
                audioSection
                notificationsSection
                appearanceSection
                upcomingProgramSection
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
                Task { await viewModel.setForceMaxVolumeEnabled(true) }
            }
        } message: {
            Text("This sets the macOS output volume for the selected device to 100% and removes software volume from the signal path. Lower the volume on your DAC, amp, or headphones first to avoid hearing damage.")
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
                title: "Buy me a coffee",
                subtitle: "buymeacoffee.com",
                url: "https://buymeacoffee.com/gvajda",
                icon: AnyView(bmcIcon)
            )
        }
    }

    private var bmcIcon: some View {
        let image: NSImage = {
            if let url = Bundle.module.url(forResource: "bmc", withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                return img
            }
            return NSImage()
        }()
        return Image(nsImage: image)
            .resizable()
            .frame(width: 18, height: 18)
    }

    private func supportButton(title: String, subtitle: String, url: String, icon: AnyView) -> some View {
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
            Toggle("Hog mode (bit-perfect)", isOn: hogModeBinding)
            Toggle("Release on Pause", isOn: releaseHogOnPauseBinding)
                .padding(.leading, 20)
                .disabled(!viewModel.hogModeEnabled)
            Toggle("Force Max Volume (for external DACs)", isOn: forceMaxVolumeBinding)
                .padding(.leading, 20)
                .disabled(!viewModel.hogModeEnabled)
            Toggle(isOn: applyReplayGainEffectiveBinding) {
                HStack(spacing: 6) {
                    Text("Apply ReplayGain")
                    HoverInfoIcon(text: "ReplayGain is a per-track loudness adjustment encoded in the file's metadata. With it ON, mpv attenuates each track to match a reference loudness so songs play at similar levels. With it OFF (default), audio is sent untouched — preferred for bit-perfect playback.")
                }
            }
            .disabled(viewModel.forceMaxVolumeEnabled)
            Picker("Bitrate", selection: bitrateBinding) {
                Text("32K AAC").tag(0)
                Text("64K AAC").tag(1)
                Text("128K AAC").tag(2)
                Text("128K MP3").tag(5)
                Text("320K AAC").tag(3)
                Text("320K MP3").tag(6)
                Text("FLAC").tag(4)
            }
        }
    }

    private var notificationsSection: some View {
        Section("Notifications") {
            Toggle("Show desktop notifications on song start", isOn: notificationsBinding)
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
            Toggle("Ambient background from album art", isOn: ambientBackgroundBinding)
        }
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
            Stepper("Rows: \(viewModel.upcomingRowCount)",
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
        let suffix = device.transportType.isBitPerfectRecommended ? "" : " (not recommended for bit-perfect)"
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

    private var forceMaxVolumeBinding: Binding<Bool> {
        Binding(
            get: { viewModel.forceMaxVolumeEnabled },
            set: { newValue in
                if newValue && !viewModel.forceMaxVolumeEnabled {
                    showForceMaxConfirm = true
                } else {
                    Task { await viewModel.setForceMaxVolumeEnabled(newValue) }
                }
            }
        )
    }

    // ReplayGain UI shows the *effective* state: forced OFF when force-max is on,
    // but the user's stored preference is preserved underneath for restore on toggle-off.
    private var applyReplayGainEffectiveBinding: Binding<Bool> {
        Binding(
            get: { viewModel.applyReplayGainEnabled && !viewModel.forceMaxVolumeEnabled },
            set: { newValue in Task { await viewModel.setApplyReplayGainEnabled(newValue) } }
        )
    }

    private var notificationsBinding: Binding<Bool> {
        Binding(
            get: { viewModel.notificationsEnabled },
            set: { newValue in Task { await viewModel.setNotificationsEnabled(newValue) } }
        )
    }

    private var appearanceBinding: Binding<AppearanceMode> {
        Binding(
            get: { viewModel.appearance },
            set: { newValue in Task { await viewModel.setAppearance(newValue) } }
        )
    }

    private var ambientBackgroundBinding: Binding<Bool> {
        Binding(
            get: { viewModel.ambientBackgroundEnabled },
            set: { newValue in Task { await viewModel.setAmbientBackgroundEnabled(newValue) } }
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
