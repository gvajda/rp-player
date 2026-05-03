import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            supportSection
            audioSection
            notificationsSection
            appearanceSection
            accountSection
            dataSection
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
        .task { await viewModel.start() }
    }

    private var supportSection: some View {
        Section {
            Link(destination: URL(string: "https://radioparadise.com/donate")!) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Support Radio Paradise")
                        Text("Opens radioparadise.com in your browser")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.pink)
                }
            }
        }
    }

    private var audioSection: some View {
        Section("Audio") {
            Picker("Output device", selection: deviceBinding) {
                Text("Select an output device").tag(String?.none)
                ForEach(viewModel.devices, id: \.uid) { device in
                    Text(deviceLabel(device)).tag(Optional(device.uid))
                }
            }
            Toggle("Hog mode (bit-perfect)", isOn: hogModeBinding)
            Toggle("Software volume control", isOn: softwareVolumeBinding)
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
            Picker("Appearance", selection: appearanceBinding) {
                Text("System").tag(AppearanceMode.system)
                Text("Light").tag(AppearanceMode.light)
                Text("Dark").tag(AppearanceMode.dark)
            }
            .pickerStyle(.menu)
            Toggle("Ambient background from album art", isOn: ambientBackgroundBinding)
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
                } else {
                    Button("Sign in") { viewModel.openLoginWindow() }
                }
            }
        }
    }

    private var dataSection: some View {
        Section("Data") {
            Button("Show application data") { viewModel.openApplicationData() }
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

    private var softwareVolumeBinding: Binding<Bool> {
        Binding(
            get: { viewModel.softwareVolumeEnabled },
            set: { newValue in Task { await viewModel.setSoftwareVolumeEnabled(newValue) } }
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
