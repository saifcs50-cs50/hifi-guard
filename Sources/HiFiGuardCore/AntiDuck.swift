import CoreAudio
import Foundation
import OSLog

/// One ducking decision coreaudiod logged for one client on one device.
public struct DuckReading: Equatable, Sendable {
    public let deviceUID: String
    public let clientID: Int
    public let pid: pid_t
    /// "Present" clients are the ones doing the ducking; they are never ducked.
    public let isPresent: Bool
    public let scalar: Float

    public init(deviceUID: String, clientID: Int, pid: pid_t, isPresent: Bool, scalar: Float) {
        self.deviceUID = deviceUID
        self.clientID = clientID
        self.pid = pid
        self.isPresent = isPresent
        self.scalar = scalar
    }
}

/// Parses coreaudiod's own record of how much it is turning each client down, e.g.
/// "HALS_Device::_GetCombinedVolumeScalar: <uid> client 1731 (pid 14611) is not present,
/// and is ducked with a combined volume scalar of 0.177828".
///
/// There is no public API for this number; the log line is the only place macOS reports
/// it. If Apple changes the wording, parsing fails and the app simply stops compensating.
public enum DuckLogParser {
    private static let pattern = try? NSRegularExpression(
        pattern: #"_GetCombinedVolumeScalar: (\S+) client (\d+) \(pid (\d+)\) (is|is not) present, and is ducked with a combined volume scalar of ([0-9]*\.?[0-9]+)"#
    )

    public static func parse(_ line: String) -> DuckReading? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = pattern?.firstMatch(in: line, range: range), match.numberOfRanges == 6 else { return nil }
        let field = { (index: Int) in Range(match.range(at: index), in: line).map { String(line[$0]) } }
        guard let uid = field(1),
              let client = field(2).flatMap({ Int($0) }),
              let pid = field(3).flatMap({ pid_t($0) }),
              let presence = field(4),
              let scalar = field(5).flatMap({ Float($0) }) else { return nil }
        return DuckReading(deviceUID: uid, clientID: client, pid: pid, isPresent: presence == "is", scalar: scalar)
    }
}

/// Reassembles whole lines from a byte stream that arrives in arbitrary chunks.
public final class LineBuffer {
    private var pending = Data()

    public init() {}

    public func append(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
            pending = pending.subdata(in: pending.index(after: newline)..<pending.endIndex)
        }
        return lines
    }
}

public enum AntiDuck {
    /// Never boost more than +20 dB, whatever the log says.
    public static let maxMakeup: Float = 10
    /// Ducks shallower than this aren't worth re-routing for.
    static let ignoreAbove: Float = 0.97

    /// How much to boost everything HiFi Guard plays so that, after macOS ducks it, it
    /// lands back at the level the user chose. Returns 1 (no boost) unless every safety
    /// condition holds: the feature is on, a call is live, and the reading is a real duck
    /// of our own audio on the device we're actually playing to.
    public static func makeup(isEnabled: Bool, isCallActive: Bool, reading: DuckReading?, outputUID: String?) -> Float {
        guard isEnabled,
              isCallActive,
              let reading,
              reading.deviceUID == outputUID,
              !reading.isPresent,
              reading.scalar > 0,
              reading.scalar < ignoreAbove else { return 1 }
        return min(1 / reading.scalar, maxMakeup)
    }
}

/// Follows coreaudiod's ducking log for this process and reports each new reading on
/// the main queue. Runs `/usr/bin/log stream` as a child process; restarts it if it exits.
public final class DuckMonitor {
    private static let predicate = #"process == "coreaudiod" AND eventMessage CONTAINS "combined volume scalar""#
    /// Restarts back off from 5 s to 5 min, so a Mac where `log stream` can't run
    /// (e.g. a non-admin account) doesn't spawn a process every few seconds forever.
    private static let firstRestartDelay: TimeInterval = 5
    private static let maxRestartDelay: TimeInterval = 300
    private static let log = Logger(subsystem: "com.saif.hifiguard", category: "duck")

    private let pid: pid_t
    private let onReading: (DuckReading) -> Void
    private let queue = DispatchQueue(label: "com.saif.hifiguard.duck-monitor")
    private let lines = LineBuffer()
    private var process: Process?
    private var isStopped = false
    private var restartDelay = DuckMonitor.firstRestartDelay

    public init(pid: pid_t = getpid(), onReading: @escaping (DuckReading) -> Void) {
        self.pid = pid
        self.onReading = onReading
    }

    public func start() {
        queue.async { self.launch() }
    }

    public func stop() {
        queue.sync {
            isStopped = true
            process?.terminate()
            process = nil
        }
    }

    private func launch() {
        guard !isStopped, process == nil else { return }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        child.arguments = ["stream", "--style", "compact", "--predicate", Self.predicate]
        let pipe = Pipe()
        child.standardOutput = pipe
        child.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            // Empty means end of stream; stop reading or the handler spins.
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async { self?.consume(chunk) }
        }
        child.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            self?.queue.async {
                guard let self else { return }
                let delay = self.restartDelay
                self.restartDelay = min(delay * 2, Self.maxRestartDelay)
                self.queue.asyncAfter(deadline: .now() + delay) {
                    self.process = nil
                    self.launch()
                }
            }
        }
        do {
            try child.run()
            process = child
            Self.log.notice("Watching coreaudiod for ducking")
        } catch {
            Self.log.error("Couldn't start log stream: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func consume(_ chunk: Data) {
        for line in lines.append(chunk) {
            restartDelay = Self.firstRestartDelay
            guard let reading = DuckLogParser.parse(line), reading.pid == pid else { continue }
            DispatchQueue.main.async { self.onReading(reading) }
        }
    }
}
