import Charts
import SwiftUI

struct Panel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quinary, in: .rect(cornerRadius: 14, style: .continuous))
    }
}

struct SpeedReadout: View {
    let bytesPerSecond: Double
    var size: CGFloat = 64
    var accent = Color.brand

    var body: some View {
        let parts = Format.speed(bytesPerSecond)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(parts.value)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: bytesPerSecond))
            Text(parts.unit)
                .font(.system(size: size * 0.32, weight: .semibold, design: .rounded))
                .foregroundStyle(accent)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .animation(.snappy, value: bytesPerSecond)
        .accessibilityElement(children: .combine)
    }
}

struct Stat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.system(.body, design: .rounded).weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SpeedChart: View {
    let samples: [SpeedSample]
    let series: [String]
    let colors: [Color]

    private var maxTime: Double { max(samples.last?.time ?? 0, 10) }
    private var maxSpeed: Double { max((samples.map(\.bytesPerSecond).max() ?? 0) / 1_000_000 * 1.15, 1) }

    var body: some View {
        Chart(samples) { sample in
            AreaMark(
                x: .value("Time", sample.time),
                y: .value("MB/s", sample.bytesPerSecond / 1_000_000),
                series: .value("Phase", sample.series),
                stacking: .unstacked
            )
            .foregroundStyle(by: .value("Phase", sample.series))
            .opacity(0.15)
            .interpolationMethod(.monotone)

            LineMark(
                x: .value("Time", sample.time),
                y: .value("MB/s", sample.bytesPerSecond / 1_000_000),
                series: .value("Phase", sample.series)
            )
            .foregroundStyle(by: .value("Phase", sample.series))
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.monotone)
        }
        .chartForegroundStyleScale(domain: series, range: colors)
        .chartLegend(series.count > 1 ? .visible : .hidden)
        .chartXScale(domain: 0...maxTime)
        .chartYScale(domain: 0...maxSpeed)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let seconds = value.as(Double.self) { Text(Format.duration(seconds)) }
                }
            }
        }
        .chartYAxis { AxisMarks(position: .leading) }
        .chartYAxisLabel("MB/s")
        .overlay {
            if samples.isEmpty {
                Text("Speed graph appears here once a transfer starts")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct LocationCard: View {
    let title: String
    let placeholder: String
    let symbol: String
    let urls: [URL]
    let detail: String
    let choose: () -> Void
    let drop: ([URL]) -> Bool

    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Button(action: choose) {
                VStack(spacing: 8) {
                    if let first = urls.first {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: first.path))
                            .resizable()
                            .frame(width: 48, height: 48)
                        Text(urls.count == 1 ? first.lastPathComponent : "\(first.lastPathComponent) + \(urls.count - 1) more")
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(Color.brand)
                            .frame(height: 48)
                        Text(placeholder)
                            .font(.headline)
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 130)
                .background(.quinary, in: .rect(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            isTargeted ? Color.brand : Color.secondary.opacity(0.35),
                            style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: urls.isEmpty ? [5, 4] : [])
                        )
                }
                .contentShape(.rect(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .dropDestination(for: URL.self) { dropped, _ in
                drop(dropped)
            } isTargeted: {
                isTargeted = $0
            }
        }
    }
}

struct ResultTile: View {
    let title: String
    let symbol: String
    let accent: Color
    let speed: Double?
    let isActive: Bool
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(isActive ? accent : .secondary)
            SpeedReadout(bytesPerSecond: speed ?? 0, size: 52, accent: accent)
                .opacity(speed == nil ? 0.25 : 1)
            ProgressView(value: progress)
                .tint(accent)
                .opacity(isActive ? 1 : 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isActive ? accent : .clear, lineWidth: 1.5)
        }
    }
}

@MainActor
enum Panels {
    static func chooseItems() -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose files or folders to copy"
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.urls : nil
    }

    static func chooseFolder(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = message
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

extension URL {
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
