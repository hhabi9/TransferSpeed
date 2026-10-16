import Foundation
import Observation

struct SpeedSample: Identifiable {
    let id = UUID()
    let time: Double
    let bytesPerSecond: Double
    let series: String
}

/// Live throughput over a ~1 s sliding window, plus a decimated history for the chart.
struct SpeedMeter {
    private(set) var samples: [SpeedSample] = []
    private(set) var current: Double = 0
    private(set) var peak: Double = 0
    private var window: [(time: Double, bytes: Int64)] = []
    private var lastPlotted = -Double.infinity

    mutating func startPhase() {
        window.removeAll()
        current = 0
    }

    mutating func stop() {
        current = 0
    }

    /// `time` is relative to the phase start; `chartTime` positions the sample on the shared x axis.
    mutating func record(bytes: Int64, time: Double, chartTime: Double, series: String) {
        window.append((time, bytes))
        while window.count > 2, time - window[1].time >= 1 { window.removeFirst() }
        if let first = window.first, time > first.time {
            current = Double(bytes - first.bytes) / (time - first.time)
            // Ignore the first half second so a burst into a cache can't set a fake peak.
            if time - first.time >= 0.5 { peak = max(peak, current) }
        }
        if chartTime - lastPlotted >= max(0.5, chartTime / 400) {
            samples.append(SpeedSample(time: chartTime, bytesPerSecond: current, series: series))
            lastPlotted = chartTime
        }
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

@MainActor @Observable
final class CopyJob {
    enum State: Equatable {
        case idle, scanning, copying, finished, cancelled
        case failed(String)
    }

    var sources: [URL] = []
    var destination: URL?
    private(set) var state = State.idle
    private(set) var totalBytes: Int64 = 0
    private(set) var copiedBytes: Int64 = 0
    private(set) var totalFiles = 0
    private(set) var completedFiles = 0
    private(set) var currentItem = ""
    private(set) var elapsed: Double = 0
    private(set) var meter = SpeedMeter()

    @ObservationIgnored private var control: TransferControl?

    var isRunning: Bool { state == .scanning || state == .copying }
    var canStart: Bool { !isRunning && !sources.isEmpty && destination != nil }
    var averageSpeed: Double { elapsed > 0 ? Double(copiedBytes) / elapsed : 0 }

    var fractionComplete: Double {
        if state == .finished { return 1 }
        return totalBytes > 0 ? min(1, Double(copiedBytes) / Double(totalBytes)) : 0
    }

    var remainingTime: Double? {
        guard state == .copying, averageSpeed > 0 else { return nil }
        return Double(totalBytes - copiedBytes) / averageSpeed
    }

    func start() {
        guard canStart, let destination else { return }
        let sources = self.sources
        let control = TransferControl()
        self.control = control
        totalBytes = 0
        copiedBytes = 0
        totalFiles = 0
        completedFiles = 0
        currentItem = ""
        elapsed = 0
        meter = SpeedMeter()
        state = .scanning

        Task {
            var sampler: Task<Void, Never>?
            do {
                let plan = try await runInBackground {
                    try CopyEngine.plan(sources: sources, into: destination, control: control)
                }
                totalBytes = plan.totalBytes
                totalFiles = plan.fileCount
                state = .copying

                let start = ContinuousClock.now
                sampler = Task {
                    while !Task.isCancelled {
                        record(control, since: start)
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
                try await runInBackground { try CopyEngine.execute(plan, control: control) }
                sampler?.cancel()
                record(control, since: start)
                state = .finished
            } catch {
                sampler?.cancel()
                state = error is CancellationError ? .cancelled : .failed(error.localizedDescription)
            }
            meter.stop()
        }
    }

    func cancel() {
        control?.cancel()
    }

    private func record(_ control: TransferControl, since start: ContinuousClock.Instant) {
        let time = (ContinuousClock.now - start).seconds
        copiedBytes = control.bytesTransferred
        completedFiles = control.filesCompleted
        currentItem = control.currentItem
        elapsed = time
        meter.record(bytes: copiedBytes, time: time, chartTime: time, series: "Copy")
    }
}

@MainActor @Observable
final class BenchmarkJob {
    enum State: Equatable {
        case idle, preparing, writing, reading, finished, cancelled
        case failed(String)
    }

    enum TestSize: Int64, CaseIterable, Identifiable {
        case one = 1, two = 2, five = 5, ten = 10

        var id: Self { self }
        var bytes: Int64 { rawValue * 1_000_000_000 }
        var label: String { "\(rawValue) GB" }
    }

    var target: URL?
    var testSize = TestSize.two
    private(set) var state = State.idle
    private(set) var writeSpeed: Double?
    private(set) var readSpeed: Double?
    private(set) var phaseProgress: Double = 0
    private(set) var meter = SpeedMeter()

    @ObservationIgnored private var control: TransferControl?
    @ObservationIgnored private var runStart = ContinuousClock.now

    var isRunning: Bool { [.preparing, .writing, .reading].contains(state) }

    func start(in folder: URL) {
        guard !isRunning else { return }
        let control = TransferControl()
        let size = testSize.bytes
        let file = BenchmarkEngine.testFileURL(in: folder)
        self.control = control
        writeSpeed = nil
        readSpeed = nil
        phaseProgress = 0
        meter = SpeedMeter()
        runStart = .now
        state = .preparing

        Task {
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            do {
                try await runInBackground { try BenchmarkEngine.checkSpace(in: folder, needed: size) }
                state = .writing
                writeSpeed = try await measure("Write", total: size, control: control) {
                    try BenchmarkEngine.write(file, size: size, control: control)
                }
                state = .reading
                readSpeed = try await measure("Read", total: size, control: control) {
                    try BenchmarkEngine.read(file, control: control)
                }
                state = .finished
            } catch {
                state = error is CancellationError ? .cancelled : .failed(error.localizedDescription)
            }
            meter.stop()
            phaseProgress = 0
            try? await runInBackground { BenchmarkEngine.removeTestFile(file) }
        }
    }

    func cancel() {
        control?.cancel()
    }

    /// Runs one phase and returns its exact average in bytes per second.
    private func measure(
        _ series: String,
        total: Int64,
        control: TransferControl,
        _ work: @escaping @Sendable () throws -> Void
    ) async throws -> Double {
        control.resetBytes()
        meter.startPhase()
        let phaseStart = ContinuousClock.now
        let sampler = Task {
            while !Task.isCancelled {
                record(series, total: total, since: phaseStart, control: control)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { sampler.cancel() }

        try await runInBackground(work)
        let elapsed = (ContinuousClock.now - phaseStart).seconds
        record(series, total: total, since: phaseStart, control: control)
        return Double(control.bytesTransferred) / elapsed
    }

    private func record(_ series: String, total: Int64, since phaseStart: ContinuousClock.Instant, control: TransferControl) {
        let now = ContinuousClock.now
        let bytes = control.bytesTransferred
        phaseProgress = min(1, Double(bytes) / Double(total))
        meter.record(bytes: bytes, time: (now - phaseStart).seconds, chartTime: (now - runStart).seconds, series: series)
    }
}
