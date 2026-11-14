import HiFiGuardCore

private func report(
    guardOn: Bool = true,
    output: AudioDevice? = Fixtures.budsHiFi,
    input: AudioDevice? = Fixtures.builtInMic,
    devices: [AudioDevice]? = nil,
    apps: [String] = []
) -> StatusReport {
    let f = Fixtures.self
    return StatusReport.make(from: StatusInput(
        isGuardOn: guardOn,
        output: output,
        input: input,
        devices: devices ?? [f.builtInMic, f.speakers, f.budsMic, output ?? f.budsHiFi],
        bluetoothMicApps: apps
    ))
}

private func contains(_ text: String?, _ fragment: String) -> Bool {
    text?.contains(fragment) ?? false
}

func runStatusReportTests() {
    let f = Fixtures.self
    Harness.suite("StatusReport") {
        Harness.test("steady state: earbuds in high quality, Mac mic in use") {
            let r = report()
            Harness.expect(r.severity, .ok, "severity")
            Harness.expect(r.outputLine, "Output: Example Earbuds", "output")
            Harness.expect(r.qualityLine, "High quality · 44.1 kHz", "quality")
            Harness.expect(r.micLine, "Mic: MacBook Pro Microphone", "mic")
            Harness.expectNil(r.warning, "warning")
        }
        Harness.test("guard off shows the off state and no warning") {
            let r = report(guardOn: false, output: f.budsCall, input: f.budsMic, apps: ["zoom.us"])
            Harness.expect(r.severity, .off, "severity")
            Harness.expectNil(r.warning, "warning")
        }
        Harness.test("names the app holding the earbuds mic and the mic to pick instead") {
            let r = report(output: f.budsCall, apps: ["zoom.us"])
            Harness.expect(r.severity, .warning, "severity")
            Harness.expect(r.qualityLine, "Call quality · 16 kHz, mono", "quality")
            Harness.expect(contains(r.warning, "zoom.us is using the earbuds mic"), true, "names zoom")
            Harness.expect(contains(r.warning, "“MacBook Pro Microphone”"), true, "suggests mic")
            Harness.expect(contains(r.warning, "that app's"), true, "singular")
        }
        Harness.test("joins several apps into one sentence") {
            let two = report(output: f.budsCall, apps: ["zoom.us", "WhatsApp"])
            Harness.expect(contains(two.warning, "zoom.us and WhatsApp are using"), true, "two")
            Harness.expect(contains(two.warning, "those apps'"), true, "plural")
            let three = report(output: f.budsCall, apps: ["A", "B", "C"])
            Harness.expect(contains(three.warning, "A, B and C are using"), true, "three")
        }
        Harness.test("call mode with no identifiable app still warns") {
            let r = report(output: f.budsCall)
            Harness.expect(r.severity, .warning, "severity")
            Harness.expect(contains(r.warning, "Something is using the earbuds mic"), true, "generic")
        }
        Harness.test("warns when no other mic exists to switch to") {
            let r = report(input: f.budsMic, devices: [f.budsMic, f.budsHiFi, f.virtualMic])
            Harness.expect(r.severity, .warning, "severity")
            Harness.expect(contains(r.warning, "No other mic is available"), true, "no mic")
        }
        Harness.test("speaker output has no quality line and no warning") {
            let r = report(output: f.speakers, apps: ["zoom.us"])
            Harness.expectNil(r.qualityLine, "quality")
            Harness.expectNil(r.warning, "warning")
            Harness.expect(r.severity, .ok, "severity")
        }
        Harness.test("handles missing devices") {
            let r = report(output: nil, input: nil, devices: [])
            Harness.expect(r.outputLine, "Output: none", "output")
            Harness.expect(r.micLine, "Mic: none", "mic")
        }
    }

    Harness.suite("Formatting") {
        Harness.test("sample rates read naturally") {
            Harness.expect(Format.kHz(44_100), "44.1 kHz", "44.1")
            Harness.expect(Format.kHz(48_000), "48 kHz", "48")
            Harness.expect(Format.kHz(16_000), "16 kHz", "16")
        }
        Harness.test("app lists join like English") {
            Harness.expect(Format.list(["A"]), "A", "one")
            Harness.expect(Format.list(["A", "B"]), "A and B", "two")
            Harness.expect(Format.list(["A", "B", "C"]), "A, B and C", "three")
        }
    }
}
