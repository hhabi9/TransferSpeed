import Foundation
import Synchronization

/// Shared between the UI and the I/O worker: progress counters plus a cancel flag.
final class TransferControl: Sendable {
    private let byteCount = Atomic<Int64>(0)
    private let fileCount = Atomic<Int>(0)
    private let cancelled = Atomic<Bool>(false)
    private let item = Mutex("")

    var bytesTransferred: Int64 { byteCount.load(ordering: .relaxed) }
    var filesCompleted: Int { fileCount.load(ordering: .relaxed) }
    var currentItem: String { item.withLock { $0 } }

    func add(bytes: Int) { byteCount.add(Int64(bytes), ordering: .relaxed) }
    func completeFile() { fileCount.add(1, ordering: .relaxed) }
    func setCurrentItem(_ name: String) { item.withLock { $0 = name } }
    func resetBytes() { byteCount.store(0, ordering: .relaxed) }
    func cancel() { cancelled.store(true, ordering: .relaxed) }

    func checkCancelled() throws {
        if cancelled.load(ordering: .relaxed) { throw CancellationError() }
    }
}

enum TransferError: LocalizedError {
    case system(operation: String, path: String, code: Int32)
    case destinationExists(String)
    case copyIntoItself(String)
    case insufficientSpace(needed: Int64, available: Int64)

    static func posix(_ operation: String, _ path: String) -> TransferError {
        .system(operation: operation, path: path, code: errno)
    }

    var errorDescription: String? {
        switch self {
        case let .system(operation, path, code):
            "Couldn’t \(operation) “\((path as NSString).lastPathComponent)”: \(String(cString: strerror(code)))."
        case let .destinationExists(name):
            "“\(name)” already exists in the destination folder."
        case let .copyIntoItself(name):
            "Can’t copy “\(name)” into itself."
        case let .insufficientSpace(needed, available):
            "Not enough free space: needs \(Format.bytes(needed)), only \(Format.bytes(available)) available."
        }
    }
}

/// Runs blocking I/O on a GCD thread so it never ties up the Swift concurrency pool.
func runInBackground<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Result(catching: work))
        }
    }
}

/// Raw POSIX I/O with the unified buffer cache disabled, so numbers reflect the device, not RAM.
enum FileIO {
    static let chunkSize = 8 << 20

    static func allocateBuffer() -> UnsafeMutableRawPointer {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: Int(getpagesize()))
        arc4random_buf(buffer, chunkSize)
        return buffer
    }

    static func open(_ path: String, _ flags: Int32, operation: String) throws -> Int32 {
        let fd = Darwin.open(path, flags, 0o644)
        guard fd >= 0 else { throw TransferError.posix(operation, path) }
        _ = fcntl(fd, F_NOCACHE, 1)
        return fd
    }

    /// Returns 0 at end of file.
    static func read(_ fd: Int32, into buffer: UnsafeMutableRawPointer, path: String) throws -> Int {
        while true {
            let count = Darwin.read(fd, buffer, chunkSize)
            if count >= 0 { return count }
            if errno != EINTR { throw TransferError.posix("read", path) }
        }
    }

    static func write(_ fd: Int32, from buffer: UnsafeRawPointer, count: Int, path: String) throws {
        var offset = 0
        while offset < count {
            let written = Darwin.write(fd, buffer + offset, count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                throw TransferError.posix("write", path)
            }
            offset += written
        }
    }
}

struct CopyPlan: Sendable {
    enum Entry: Sendable {
        case directory(source: URL, destination: URL)
        case file(source: URL, destination: URL)
        case symlink(destination: URL, target: String)
    }

    var entries: [Entry] = []
    var totalBytes: Int64 = 0
    var fileCount = 0
}

enum CopyEngine {
    private static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
    private static let metadataFlags = copyfile_flags_t(COPYFILE_SECURITY | COPYFILE_XATTR | COPYFILE_STAT)

    static func plan(sources: [URL], into folder: URL, control: TransferControl) throws -> CopyPlan {
        var plan = CopyPlan()
        let folderPath = folder.standardizedFileURL.path
        for source in sources {
            let name = source.lastPathComponent
            let sourcePath = source.standardizedFileURL.path
            if folderPath == sourcePath || folderPath.hasPrefix(sourcePath + "/") {
                throw TransferError.copyIntoItself(name)
            }
            let destination = folder.appending(path: name)
            var info = stat()
            if lstat(destination.path, &info) == 0 { throw TransferError.destinationExists(name) }
            try collect(source, to: destination, into: &plan, control: control)
        }
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values?.volumeAvailableCapacityForImportantUsage, available > 0, available < plan.totalBytes {
            throw TransferError.insufficientSpace(needed: plan.totalBytes, available: available)
        }
        return plan
    }

    static func execute(_ plan: CopyPlan, control: TransferControl) throws {
        let buffer = FileIO.allocateBuffer()
        defer { buffer.deallocate() }
        let fileManager = FileManager.default
        var directories: [(source: URL, destination: URL)] = []

        for entry in plan.entries {
            try control.checkCancelled()
            switch entry {
            case let .directory(source, destination):
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
                directories.append((source, destination))
            case let .symlink(destination, target):
                try fileManager.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
            case let .file(source, destination):
                control.setCurrentItem(source.lastPathComponent)
                try copyFile(source, to: destination, buffer: buffer, control: control)
                control.completeFile()
            }
        }
        // Children are done, so directory timestamps won't be bumped again.
        for (source, destination) in directories.reversed() {
            copyfile(source.path, destination.path, nil, metadataFlags)
        }
    }

    private static func collect(_ source: URL, to destination: URL, into plan: inout CopyPlan, control: TransferControl) throws {
        try control.checkCancelled()
        let values = try source.resourceValues(forKeys: keys)
        if values.isSymbolicLink == true {
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: source.path)
            plan.entries.append(.symlink(destination: destination, target: target))
        } else if values.isDirectory == true {
            plan.entries.append(.directory(source: source, destination: destination))
            let children = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: Array(keys))
            for child in children {
                try collect(child, to: destination.appending(path: child.lastPathComponent), into: &plan, control: control)
            }
        } else if values.isRegularFile == true {
            plan.entries.append(.file(source: source, destination: destination))
            plan.totalBytes += Int64(values.fileSize ?? 0)
            plan.fileCount += 1
        }
    }

    private static func copyFile(_ source: URL, to destination: URL, buffer: UnsafeMutableRawPointer, control: TransferControl) throws {
        let input = try FileIO.open(source.path, O_RDONLY, operation: "open")
        defer { close(input) }
        let output = try FileIO.open(destination.path, O_WRONLY | O_CREAT | O_EXCL, operation: "create")
        var finished = false
        defer {
            close(output)
            if !finished { unlink(destination.path) }
        }

        while true {
            try control.checkCancelled()
            let count = try FileIO.read(input, into: buffer, path: source.path)
            if count == 0 { break }
            try FileIO.write(output, from: buffer, count: count, path: destination.path)
            control.add(bytes: count)
        }
        fcopyfile(input, output, nil, metadataFlags)
        finished = true
    }
}

enum BenchmarkEngine {
    static func testFileURL(in folder: URL) -> URL {
        folder.appending(path: ".TransferSpeed-\(UUID().uuidString).tmp")
    }

    static func checkSpace(in folder: URL, needed: Int64) throws {
        let values = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let available = values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init)
        let margin: Int64 = 256_000_000
        if let available, available > 0, available < needed + margin {
            throw TransferError.insufficientSpace(needed: needed, available: available)
        }
    }

    static func write(_ url: URL, size: Int64, control: TransferControl) throws {
        let buffer = FileIO.allocateBuffer()
        defer { buffer.deallocate() }
        let fd = try FileIO.open(url.path, O_WRONLY | O_CREAT | O_EXCL, operation: "create")
        defer { close(fd) }

        var remaining = size
        while remaining > 0 {
            try control.checkCancelled()
            let count = Int(min(Int64(FileIO.chunkSize), remaining))
            try FileIO.write(fd, from: buffer, count: count, path: url.path)
            control.add(bytes: count)
            remaining -= Int64(count)
        }
        // Count the flush to the device, not just the hand-off to the kernel. Network shares may not support F_FULLFSYNC.
        if fcntl(fd, F_FULLFSYNC) != 0 { fsync(fd) }
    }

    static func read(_ url: URL, control: TransferControl) throws {
        let buffer = FileIO.allocateBuffer()
        defer { buffer.deallocate() }
        let fd = try FileIO.open(url.path, O_RDONLY, operation: "open")
        defer { close(fd) }

        while true {
            try control.checkCancelled()
            let count = try FileIO.read(fd, into: buffer, path: url.path)
            if count == 0 { break }
            control.add(bytes: count)
        }
    }

    static func removeTestFile(_ url: URL) {
        unlink(url.path)
    }
}
