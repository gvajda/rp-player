import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            audioSection
            notificationsSection
            accountSection
            dataSection
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
        .task { await viewModel.start() }
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
                Text("AAC 64 kbps").tag(0)
                Text("AAC 128 kbps").tag(1)
                Text("MP3 320 kbps").tag(2)
                Text("FLAC").tag(3)
                Text("FLAC (with metadata)").tag(4)
            }
        }
    }

    private var notificationsSection: some View {
        Section("Notifications") {
            Toggle("Show desktop notifications on song start", isOn: notificationsBinding)
        }
    }

    private var accountSection: some View {
        Section("Account") {
            HStack {
                Text(viewModel.isSignedIn ? "Signed in" : "Anonymous")
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

    private var bitrateBinding: Binding<Int> {
        Binding(
            get: { viewModel.bitrate },
            set: { newValue in Task { await viewModel.setBitrate(newValue) } }
        )
    }
}
