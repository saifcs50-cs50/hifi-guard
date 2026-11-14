import CoreAudio
import HiFiGuardCore
import SwiftUI

struct PanelView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GuardSection(model: model)
            Divider()
            CallSection(model: model)
            Divider()
            MixerSection(model: model)
            Divider()
            FooterSection(model: model)
        }
        .padding(14)
        .frame(width: 330)
    }
}

// MARK: - Bluetooth quality

private struct GuardSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { model.isGuardOn }, set: { _ in model.toggleGuard() })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep earbuds in high quality")
                        .font(.body.weight(.semibold))
                    Text("Calls use your Mac's mic, so Bluetooth never drops to muffled call mode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            if let report = model.report {
                StatusLines(report: report, model: model)
            }
        }
    }
}

private struct StatusLines: View {
    let report: StatusReport
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DevicePicker(
                systemImage: "headphones",
                devices: model.outputs,
                selectedID: model.currentOutputID,
                title: \.name,
                onSelect: model.selectOutput
            )
            if let quality = report.qualityLine {
                Label {
                    Text(quality)
                } icon: {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(quality.hasPrefix("High") ? .green : .orange)
                }
                .padding(.leading, 22)
            }
            DevicePicker(
                systemImage: "mic",
                devices: model.inputs,
                selectedID: model.currentInputID,
                title: { $0.isBluetoothMic ? "\($0.name) (call quality)" : $0.name },
                onSelect: model.selectInput
            )
            if let warning = report.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(nil)
    }
}

/// A one-click device switcher, so changing mic or output never needs System Settings.
private struct DevicePicker: View {
    let systemImage: String
    let devices: [AudioDevice]
    let selectedID: AudioObjectID?
    let title: (AudioDevice) -> String
    let onSelect: (AudioDevice) -> Void

    var body: some View {
        Menu {
            ForEach(devices, id: \.id) { device in
                Button { onSelect(device) } label: {
                    if device.id == selectedID {
                        Label(title(device), systemImage: "checkmark")
                    } else {
                        Text(title(device))
                    }
                }
            }
        } label: {
            Label(devices.first { $0.id == selectedID }.map(title) ?? "None", systemImage: systemImage)
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Switch device")
    }
}

// MARK: - Calls

private struct CallSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { model.isAntiDuckOn }, set: { _ in model.toggleAntiDuck() })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep other audio loud during calls")
                        .font(.body.weight(.semibold))
                    Text("Calls normally turn everything else down. This puts it back.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            if let status = model.antiDuckStatus {
                Label(status, systemImage: "phone.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Per-app volume

private struct MixerSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("App volume")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            if model.permission == .denied {
                Notice(
                    text: "Turn on HiFi Guard under “System Audio Recording Only” to change app volumes.",
                    action: ("Open Privacy Settings", model.openPrivacySettings)
                )
            }
            if let error = model.lastError {
                Notice(text: error, action: ("Dismiss", model.dismissError))
            }
            if model.rows.isEmpty {
                Text("Apps show up here when they play sound.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.rows) { row in
                AppVolumeRow(row: row, model: model)
            }
        }
    }
}

private struct AppVolumeRow: View {
    let row: AppRow
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button { model.toggleMute(for: row.id) } label: { icon }
                .buttonStyle(.plain)
                .disabled(row.isInCall)
                .help(row.volume.isMuted ? "Unmute \(row.name)" : "Mute \(row.name)")

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(row.name).lineLimit(1)
                    if row.isPlaying {
                        Image(systemName: "waveform")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(row.volume.isMuted ? "Muted" : "\(row.volume.percent)%") {
                        model.resetVolume(for: row.id)
                    }
                    .buttonStyle(.plain)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(row.volume.percent > 100 ? .orange : .secondary)
                    .help("Reset to 100%")
                }
                if row.isInCall {
                    // Never touched mid-call, so nothing here can make the other person quieter.
                    Text("On a call. Plays untouched until the call ends.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Slider(value: percent, in: 0...Double(VolumeCurve.maxPercent))
                        .controlSize(.small)
                        .disabled(row.volume.isMuted)
                }
            }
        }
    }

    private var icon: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: model.icon(for: row.id))
                .resizable()
                .frame(width: 26, height: 26)
                .opacity(row.volume.isMuted ? 0.35 : 1)
            if row.volume.isMuted {
                Image(systemName: "speaker.slash.fill")
                    .font(.system(size: 8, weight: .bold))
                    .padding(3)
                    .background(.regularMaterial, in: Circle())
            }
        }
    }

    private var percent: Binding<Double> {
        Binding(
            get: { Double(row.volume.percent) },
            set: { model.setVolume(Int($0.rounded()), for: row.id) }
        )
    }
}

private struct Notice: View {
    let text: String
    let action: (String, () -> Void)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Button(action.0, action: action.1)
                .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Footer

private struct FooterSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack {
            Toggle("Open at login", isOn: Binding(get: { model.isLoginItem }, set: { _ in model.toggleLoginItem() }))
                .toggleStyle(.checkbox)
                .font(.caption)
            Spacer()
            Button("Sound Settings…", action: model.openSoundSettings)
                .controlSize(.small)
            Button("Quit") { NSApp.terminate(nil) }
                .controlSize(.small)
        }
    }
}
