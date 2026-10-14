import SwiftUI

struct CopyView: View {
    @Bindable var job: CopyJob

    private let statColumns = Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .leading), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .bottom, spacing: 14) {
                LocationCard(
                    title: "From",
                    placeholder: "Files or Folders",
                    symbol: "doc.on.doc",
                    urls: job.sources,
                    detail: sourceDetail,
                    choose: { if let urls = Panels.chooseItems() { job.sources = urls } },
                    drop: { urls in
                        guard !job.isRunning, !urls.isEmpty else { return false }
                        job.sources = urls
                        return true
                    }
                )
                Image(systemName: "arrow.right")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 52)
                LocationCard(
                    title: "To",
                    placeholder: "Destination Folder",
                    symbol: "folder",
                    urls: job.destination.map { [$0] } ?? [],
                    detail: destinationDetail,
                    choose: { if let url = Panels.chooseFolder(message: "Choose where to copy to") { job.destination = url } },
                    drop: { urls in
                        guard !job.isRunning, let folder = urls.first(where: \.isDirectory) else { return false }
                        job.destination = folder
                        return true
                    }
                )
            }
            .disabled(job.isRunning)

            Panel {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(caption)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        SpeedReadout(bytesPerSecond: readoutSpeed)
                            .opacity(job.state == .idle ? 0.25 : 1)
                    }
                    ProgressView(value: job.fractionComplete)
                    SpeedChart(samples: job.meter.samples, series: ["Copy"], colors: [.brand])
                        .frame(minHeight: 120, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)

            LazyVGrid(columns: statColumns, alignment: .leading, spacing: 14) {
                Stat(title: "Copied", value: hasStats ? "\(Format.bytes(job.copiedBytes)) of \(Format.bytes(job.totalBytes))" : "—")
                Stat(title: "Files", value: hasStats ? "\(job.completedFiles) of \(job.totalFiles)" : "—")
                Stat(title: "Elapsed", value: Format.duration(hasStats ? job.elapsed : nil))
                Stat(title: "Remaining", value: Format.duration(job.remainingTime))
                Stat(title: "Average", value: hasStats ? Format.speedText(job.averageSpeed) : "—")
                Stat(title: "Peak", value: hasStats ? Format.speedText(job.meter.peak) : "—")
            }
            .padding(.horizontal, 4)

            HStack(spacing: 12) {
                footerMessage
                Spacer()
                actionButtons
            }
        }
        .padding(24)
    }

    private var hasStats: Bool {
        job.state == .copying || job.totalFiles > 0
    }

    private var readoutSpeed: Double {
        job.state == .finished ? job.averageSpeed : job.meter.current
    }

    private var caption: String {
        switch job.state {
        case .idle: "Current speed"
        case .scanning: "Scanning…"
        case .copying: "Current speed · \(job.fractionComplete.formatted(.percent.precision(.fractionLength(0))))"
        case .finished: "Finished · average speed"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        }
    }

    @ViewBuilder private var footerMessage: some View {
        switch job.state {
        case .copying:
            Label(job.currentItem, systemImage: "doc")
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var actionButtons: some View {
        if job.isRunning {
            Button("Cancel", role: .cancel) { job.cancel() }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
        } else {
            if job.state == .finished, let destination = job.destination {
                Button("Show in Finder") {
                    let copied = job.sources.map { destination.appending(path: $0.lastPathComponent) }
                    NSWorkspace.shared.activateFileViewerSelecting(copied)
                }
                .controlSize(.large)
            }
            Button { job.start() } label: {
                Label("Start Copy", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!job.canStart)
        }
    }

    private var sourceDetail: String {
        guard let first = job.sources.first else { return "Drop here or click to choose" }
        let parent = (first.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        return job.sources.count == 1 ? parent : "\(job.sources.count) items · \(parent)"
    }

    private var destinationDetail: String {
        guard let folder = job.destination else { return "Drop a folder or click to choose" }
        let values = try? folder.resourceValues(forKeys: [.volumeLocalizedNameKey, .volumeAvailableCapacityForImportantUsageKey])
        var parts = [values?.volumeLocalizedName ?? (folder.path as NSString).abbreviatingWithTildeInPath]
        if let free = values?.volumeAvailableCapacityForImportantUsage {
            parts.append("\(Format.bytes(free)) free")
        }
        return parts.joined(separator: " · ")
    }
}
