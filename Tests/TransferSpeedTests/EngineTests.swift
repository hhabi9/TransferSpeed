import Foundation
import Testing
@testable import TransferSpeed

@Suite final class EngineTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "TransferSpeedTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFile(_ url: URL, size: Int) throws -> Data {
        var data = Data(count: size)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, size) }
        try data.write(to: url)
        return data
    }

    @Test func copiesTreeWithContentsAndSymlinks() throws {
        let source = root.appending(path: "src")
        let nested = source.appending(path: "nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let big = try makeFile(source.appending(path: "big.bin"), size: 20 << 20 + 123)
        let small = try makeFile(nested.appending(path: "small.txt"), size: 17)
        _ = try makeFile(nested.appending(path: "empty"), size: 0)
        try FileManager.default.createSymbolicLink(atPath: source.appending(path: "link").path, withDestinationPath: "big.bin")

        let destination = root.appending(path: "dst")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let control = TransferControl()
        let plan = try CopyEngine.plan(sources: [source], into: destination, control: control)
        #expect(plan.fileCount == 3)
        #expect(plan.totalBytes == Int64(big.count + small.count))

        try CopyEngine.execute(plan, control: control)
        let copied = destination.appending(path: "src")
        #expect(try Data(contentsOf: copied.appending(path: "big.bin")) == big)
        #expect(try Data(contentsOf: copied.appending(path: "nested/small.txt")) == small)
        #expect(try Data(contentsOf: copied.appending(path: "nested/empty")).isEmpty)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: copied.appending(path: "link").path) == "big.bin")
        #expect(control.bytesTransferred == plan.totalBytes)
        #expect(control.filesCompleted == 3)
    }

    @Test func refusesToOverwriteOrCopyIntoItself() throws {
        let source = root.appending(path: "a")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let control = TransferControl()

        #expect(throws: TransferError.self) {
            try CopyEngine.plan(sources: [source], into: root, control: control)
        }
        #expect(throws: TransferError.self) {
            try CopyEngine.plan(sources: [source], into: source.appending(path: "inner"), control: control)
        }
    }

    @Test func cancelledCopyLeavesNoPartialFile() throws {
        let source = root.appending(path: "file.bin")
        _ = try makeFile(source, size: 1 << 20)
        let destination = root.appending(path: "out")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let control = TransferControl()
        let plan = try CopyEngine.plan(sources: [source], into: destination, control: control)
        control.cancel()
        #expect(throws: CancellationError.self) { try CopyEngine.execute(plan, control: control) }
        #expect(!FileManager.default.fileExists(atPath: destination.appending(path: "file.bin").path))
    }

    @Test func benchmarkWritesAndReadsExactSize() throws {
        let file = BenchmarkEngine.testFileURL(in: root)
        let size: Int64 = 50_000_000
        let control = TransferControl()

        try BenchmarkEngine.write(file, size: size, control: control)
        #expect(control.bytesTransferred == size)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64 == size)

        control.resetBytes()
        try BenchmarkEngine.read(file, control: control)
        #expect(control.bytesTransferred == size)

        BenchmarkEngine.removeTestFile(file)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @MainActor @Test func copyJobRunsToCompletion() async throws {
        let source = root.appending(path: "movie.bin")
        let data = try makeFile(source, size: 64 << 20)
        let destination = root.appending(path: "job-out")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let job = CopyJob()
        job.sources = [source]
        job.destination = destination
        job.start()
        while job.isRunning { try await Task.sleep(for: .milliseconds(20)) }

        #expect(job.state == .finished)
        #expect(job.copiedBytes == Int64(data.count))
        #expect(job.fractionComplete == 1)
        #expect(job.averageSpeed > 0)
        #expect(try Data(contentsOf: destination.appending(path: "movie.bin")) == data)

        job.start()
        while job.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        #expect(job.state == .failed(TransferError.destinationExists("movie.bin").localizedDescription))
    }

    @Test func meterReportsWindowedRate() {
        var meter = SpeedMeter()
        for step in 0...8 {
            let time = Double(step) * 0.25
            meter.record(bytes: Int64(time * 100_000_000), time: time, chartTime: time, series: "Copy")
        }
        #expect(abs(meter.current - 100_000_000) < 1)
        #expect(abs(meter.peak - 100_000_000) < 1)
        #expect(!meter.samples.isEmpty)
    }
}
