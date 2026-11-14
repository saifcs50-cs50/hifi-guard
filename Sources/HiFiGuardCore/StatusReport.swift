import Foundation

public struct StatusInput: Equatable, Sendable {
    public let isGuardOn: Bool
    public let output: AudioDevice?
    public let input: AudioDevice?
    public let devices: [AudioDevice]
    public let bluetoothMicApps: [String]

    public init(
        isGuardOn: Bool,
        output: AudioDevice?,
        input: AudioDevice?,
        devices: [AudioDevice],
        bluetoothMicApps: [String]
    ) {
        self.isGuardOn = isGuardOn
        self.output = output
        self.input = input
        self.devices = devices
        self.bluetoothMicApps = bluetoothMicApps
    }
}

public enum Severity: Equatable, Sendable {
    case ok, off, warning
}

/// Everything the menu shows, derived from one audio snapshot.
public struct StatusReport: Equatable, Sendable {
    public let outputLine: String
    public let qualityLine: String?
    public let micLine: String
    public let warning: String?
    public let severity: Severity

    public static func make(from input: StatusInput) -> StatusReport {
        let mode = LinkQuality.mode(of: input.output)
        let warning = input.isGuardOn ? warningText(for: input, mode: mode) : nil
        return StatusReport(
            outputLine: "Output: \(input.output?.name ?? "none")",
            qualityLine: qualityText(mode: mode, rate: input.output?.sampleRate ?? 0),
            micLine: "Mic: \(input.input?.name ?? "none")",
            warning: warning,
            severity: !input.isGuardOn ? .off : (warning == nil ? .ok : .warning)
        )
    }

    private static func qualityText(mode: LinkMode, rate: Double) -> String? {
        switch mode {
        case .highQuality: return "High quality · \(Format.kHz(rate))"
        case .callMode: return "Call quality · \(Format.kHz(rate)), mono"
        case .notBluetooth: return nil
        }
    }

    private static func warningText(for input: StatusInput, mode: LinkMode) -> String? {
        guard mode != .notBluetooth else { return nil }
        let preferred = MicPolicy.preferredMic(among: input.devices)

        if input.input?.isBluetoothMic == true, preferred == nil {
            return "No other mic is available (lid closed?), so calls will use the earbuds mic in call quality."
        }
        let micName = preferred?.name ?? "your Mac's microphone"
        let apps = input.bluetoothMicApps
        if !apps.isEmpty {
            let verb = apps.count == 1 ? "is" : "are"
            let whose = apps.count == 1 ? "that app's" : "those apps'"
            return "\(Format.list(apps)) \(verb) using the earbuds mic, which drops them to call quality. "
                + "Choose “\(micName)” as the microphone in \(whose) audio settings."
        }
        if mode == .callMode {
            return "Something is using the earbuds mic, which drops them to call quality. "
                + "Choose “\(micName)” in your call app's audio settings."
        }
        return nil
    }
}

public enum Format {
    public static func kHz(_ rate: Double) -> String {
        let value = rate / 1_000
        return value == value.rounded() ? "\(Int(value)) kHz" : String(format: "%.1f kHz", value)
    }

    public static func list(_ items: [String]) -> String {
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }
}
