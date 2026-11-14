import CoreAudio
import HiFiGuardCore

func makeDevice(
    _ id: AudioObjectID,
    _ name: String,
    _ transport: Transport,
    input: Bool = false,
    output: Bool = false,
    rate: Double = 48_000
) -> AudioDevice {
    AudioDevice(
        id: id,
        uid: "uid-\(id)",
        name: name,
        transport: transport,
        hasInput: input,
        hasOutput: output,
        sampleRate: rate
    )
}

enum Fixtures {
    static let builtInMic = makeDevice(1, "MacBook Pro Microphone", .builtIn, input: true)
    static let speakers = makeDevice(2, "MacBook Pro Speakers", .builtIn, output: true)
    static let budsMic = makeDevice(3, "Example Earbuds", .bluetooth, input: true, rate: 16_000)
    static let budsHiFi = makeDevice(4, "Example Earbuds", .bluetooth, output: true, rate: 44_100)
    static let budsCall = makeDevice(4, "Example Earbuds", .bluetooth, output: true, rate: 16_000)
    static let usbMic = makeDevice(5, "Yeti", .usb, input: true)
    static let virtualMic = makeDevice(6, "eqMac", .virtual, input: true)
    static let aggregateMic = makeDevice(7, "Multi-Output Device", .aggregate, input: true)
    static let continuityMic = makeDevice(8, "iPhone Microphone", .other, input: true)
}

func runTransportTests() {
    Harness.suite("Transport") {
        Harness.test("maps Core Audio transport codes") {
            Harness.expect(Transport(coreAudioCode: kAudioDeviceTransportTypeBuiltIn), .builtIn, "built-in")
            Harness.expect(Transport(coreAudioCode: kAudioDeviceTransportTypeBluetooth), .bluetooth, "classic")
            Harness.expect(Transport(coreAudioCode: kAudioDeviceTransportTypeBluetoothLE), .bluetooth, "LE")
            Harness.expect(Transport(coreAudioCode: kAudioDeviceTransportTypeUSB), .usb, "usb")
            Harness.expect(Transport(coreAudioCode: kAudioDeviceTransportTypeVirtual), .virtual, "virtual")
            Harness.expect(Transport(coreAudioCode: kAudioDeviceTransportTypeAggregate), .aggregate, "aggregate")
            Harness.expect(Transport(coreAudioCode: kAudioDeviceTransportTypeAutoAggregate), .aggregate, "auto")
            Harness.expect(Transport(coreAudioCode: kAudioDeviceTransportTypeThunderbolt), .other, "thunderbolt")
        }
    }
}

func runMicPolicyTests() {
    let f = Fixtures.self
    Harness.suite("MicPolicy") {
        Harness.test("switches a Bluetooth default mic to the built-in mic") {
            let pick = MicPolicy.replacement(for: f.budsMic, among: [f.builtInMic, f.budsMic, f.budsHiFi])
            Harness.expect(pick, f.builtInMic, "replacement")
        }
        Harness.test("leaves a non-Bluetooth default mic alone") {
            Harness.expectNil(MicPolicy.replacement(for: f.builtInMic, among: [f.builtInMic, f.budsMic]), "no-op")
            Harness.expectNil(MicPolicy.replacement(for: f.usbMic, among: [f.builtInMic, f.usbMic]), "usb kept")
        }
        Harness.test("prefers the built-in mic over USB whatever the device order") {
            let pick = MicPolicy.replacement(for: f.budsMic, among: [f.usbMic, f.continuityMic, f.builtInMic, f.budsMic])
            Harness.expect(pick, f.builtInMic, "built-in first")
        }
        Harness.test("falls back to USB when the built-in mic is gone (lid closed)") {
            let pick = MicPolicy.replacement(for: f.budsMic, among: [f.continuityMic, f.usbMic, f.budsMic])
            Harness.expect(pick, f.usbMic, "usb fallback")
        }
        Harness.test("falls back to other real mics last") {
            let pick = MicPolicy.replacement(for: f.budsMic, among: [f.continuityMic, f.budsMic])
            Harness.expect(pick, f.continuityMic, "continuity fallback")
        }
        Harness.test("never picks virtual or aggregate devices, which record silence") {
            let pick = MicPolicy.replacement(for: f.budsMic, among: [f.virtualMic, f.aggregateMic, f.budsMic])
            Harness.expectNil(pick, "no real mic")
        }
        Harness.test("returns nil when there is no default input") {
            Harness.expectNil(MicPolicy.replacement(for: nil, among: [f.builtInMic]), "nil input")
        }
        Harness.test("ignores output-only devices") {
            Harness.expectNil(MicPolicy.preferredMic(among: [f.speakers, f.budsHiFi, f.budsMic]), "outputs")
        }
    }
}

func runLinkQualityTests() {
    let f = Fixtures.self
    Harness.suite("LinkQuality") {
        Harness.test("music-mode Bluetooth reports high quality") {
            Harness.expect(LinkQuality.mode(of: f.budsHiFi), .highQuality, "44.1 kHz")
            let at48 = makeDevice(9, "AirPods", .bluetooth, output: true, rate: 48_000)
            Harness.expect(LinkQuality.mode(of: at48), .highQuality, "48 kHz")
        }
        Harness.test("hands-free rates report call mode") {
            Harness.expect(LinkQuality.mode(of: f.budsCall), .callMode, "16 kHz")
            for rate in [8_000.0, 24_000.0] {
                let device = makeDevice(9, "Headset", .bluetooth, output: true, rate: rate)
                Harness.expect(LinkQuality.mode(of: device), .callMode, "\(rate)")
            }
        }
        Harness.test("an unreadable rate is not treated as call mode") {
            let unknown = makeDevice(9, "Headset", .bluetooth, output: true, rate: 0)
            Harness.expect(LinkQuality.mode(of: unknown), .highQuality, "rate 0")
        }
        Harness.test("non-Bluetooth outputs have no link mode") {
            Harness.expect(LinkQuality.mode(of: f.speakers), .notBluetooth, "speakers")
            Harness.expect(LinkQuality.mode(of: nil), .notBluetooth, "none")
        }
    }
}

func runMicUserTests() {
    func recorder(_ pid: pid_t, _ bundleID: String, recording: Bool, devices: [AudioObjectID]) -> AudioProcess {
        AudioProcess(
            objectID: AudioObjectID(pid),
            pid: pid,
            bundleID: bundleID,
            isRunningInput: recording,
            isRunningOutput: false,
            inputDeviceIDs: devices
        )
    }
    let zoom = recorder(10, "us.zoom.xos", recording: true, devices: [3])
    let chrome = recorder(11, "com.google.Chrome.helper", recording: true, devices: [1])
    let idle = recorder(12, "net.whatsapp.WhatsApp", recording: false, devices: [3])
    let me = recorder(99, "com.example.hifiguard", recording: true, devices: [3])
    let all = [zoom, chrome, idle, me]

    Harness.suite("MicUsers") {
        Harness.test("finds processes recording from a Bluetooth mic") {
            Harness.expect(MicUsers.processes(using: [3], among: all, excluding: 99), [zoom], "zoom only")
        }
        Harness.test("returns nothing when no Bluetooth mic exists") {
            Harness.expect(MicUsers.processes(using: [], among: all, excluding: 99), [], "empty")
        }
        Harness.test("counts a process on any of several Bluetooth mics") {
            Harness.expect(MicUsers.processes(using: [1, 3], among: all, excluding: 99), [zoom, chrome], "both")
        }
    }

    Harness.suite("BundleIDs") {
        Harness.test("lists parent bundle IDs from shortest to longest") {
            Harness.expect(
                BundleIDs.lineage(of: "com.google.Chrome.helper"),
                ["com.google", "com.google.Chrome", "com.google.Chrome.helper"],
                "chrome helper"
            )
        }
        Harness.test("keeps one-part IDs as they are") {
            Harness.expect(BundleIDs.lineage(of: "zoom"), ["zoom"], "single")
        }
    }
}

func runDeviceChoiceTests() {
    let f = Fixtures.self
    let all = [f.builtInMic, f.speakers, f.budsMic, f.budsHiFi, f.usbMic, f.virtualMic, f.aggregateMic]
    Harness.suite("DeviceChoice") {
        Harness.test("offers every real mic, including the earbuds and virtual ones") {
            Harness.expect(DeviceChoice.inputs(all).map(\.id), [1, 3, 5, 6], "inputs")
        }
        Harness.test("offers every output") {
            Harness.expect(DeviceChoice.outputs(all).map(\.id), [2, 4], "outputs")
        }
        Harness.test("picking the earbuds mic turns the guard off so it isn't switched back") {
            Harness.expect(DeviceChoice.isGuardOn(afterPicking: f.budsMic, wasOn: true), false, "bluetooth")
        }
        Harness.test("picking any other mic leaves the guard as it was") {
            Harness.expect(DeviceChoice.isGuardOn(afterPicking: f.builtInMic, wasOn: true), true, "on stays on")
            Harness.expect(DeviceChoice.isGuardOn(afterPicking: f.usbMic, wasOn: false), false, "off stays off")
        }
    }
}
