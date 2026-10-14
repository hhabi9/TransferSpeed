import SwiftUI

struct BenchmarkTarget: Identifiable, Hashable {
    let url: URL
    let name: String
    let symbol: String
    var id: URL { url }

    static func mountedVolumes() -> [BenchmarkTarget] {
        let keys: [URLResourceKey] = [
            .volumeLocalizedNameKey, .volumeIsReadOnlyKey, .volumeIsInternalKey,
            .volumeIsLocalKey, .volumeIsRootFileSystemKey,
        ]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let name = values.volumeLocalizedName ?? url.lastPathComponent
            // The system volume is sealed read-only; the temp folder lives on the same disk's data volume.
            if values.volumeIsRootFileSystem == true {
                return BenchmarkTarget(url: FileManager.default.temporaryDirectory, name: name, symbol: "internaldrive")
            }
            if values.volumeIsReadOnly == true { return nil }
            let symbol = values.volumeIsLocal == false ? "network" : values.volumeIsInternal == true ? "internaldrive" : "externaldrive"
            return BenchmarkTarget(url: url, name: name, symbol: symbol)
        }
    }
}

struct BenchmarkView: View {
    @Bindable var job: BenchmarkJob
    @State private var volumes = BenchmarkTarget.mountedVolumes()
    @State private var folders: [BenchmarkTarget] = []

    private let workspace = NSWorkspace.shared.notificationCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Group {
                    Picker("Drive", selection: $job.target) {
                        ForEach(volumes + folders) { target in
                            Label(target.name, systemImage: target.symbol).tag(Optional(target.url))
                        }
                    }
                    .frame(maxWidth: 280)
                    Button("Choose Folder…", action: chooseFolder)
                    Picker("Test size", selection: $job.testSize) {
                        ForEach(BenchmarkJob.TestSize.allCases) { Text($0.label).tag($0) }
                    }
                    .fixedSize()
                }
                .disabled(job.isRunning)
                Spacer()
                actionButton
            }

            HStack(spacing: 16) {
                ResultTile(
                    title: "Write",
                    symbol: "square.and.arrow.down",
                    accent: .brand,
                    speed: job.state == .writing ? job.meter.current : job.writeSpeed,
                    isActive: job.state == .writing,
                    progress: job.phaseProgress
                )
                ResultTile(
                    title: "Read",
                    symbol: "square.and.arrow.up",
                    accent: .readAccent,
                    speed: job.state == .reading ? job.meter.current : job.readSpeed,
                    isActive: job.state == .reading,
                    progress: job.phaseProgress
                )
            }

            Panel {
                SpeedChart(samples: job.meter.samples, series: ["Write", "Read"], colors: [.brand, .readAccent])
                    .frame(minHeight: 160, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)

            footer
                .font(.callout)
        }
        .padding(24)
        .onAppear {
            if job.target == nil { job.target = volumes.first?.url }
        }
        .onReceive(workspace.publisher(for: NSWorkspace.didMountNotification)) { _ in refreshVolumes() }
        .onReceive(workspace.publisher(for: NSWorkspace.didUnmountNotification)) { _ in refreshVolumes() }
    }

    @ViewBuilder private var actionButton: some View {
        if job.isRunning {
            Button("Cancel", role: .cancel) { job.cancel() }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
        } else {
            Button { job.start() } label: {
                Label("Start Test", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(job.target == nil)
        }
    }

    @ViewBuilder private var footer: some View {
        switch job.state {
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .preparing:
            Text("Checking free space…")
                .foregroundStyle(.secondary)
        case .cancelled:
            Text("Cancelled. The test file was removed.")
                .foregroundStyle(.secondary)
        default:
            Text("Writes a \(job.testSize.label) test file with caching off, flushes it to the device, reads it back, then deletes it.")
                .foregroundStyle(.secondary)
        }
    }

    private func chooseFolder() {
        guard let url = Panels.chooseFolder(message: "Choose a folder on the drive to test") else { return }
        if !folders.contains(where: { $0.url == url }) {
            folders.append(BenchmarkTarget(url: url, name: url.lastPathComponent, symbol: "folder"))
        }
        job.target = url
    }

    private func refreshVolumes() {
        volumes = BenchmarkTarget.mountedVolumes()
        let all = volumes + folders
        if !job.isRunning, !all.contains(where: { $0.url == job.target }) {
            job.target = all.first?.url
        }
    }
}
