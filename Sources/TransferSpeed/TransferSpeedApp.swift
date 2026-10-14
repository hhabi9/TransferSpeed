import SwiftUI

@main
struct TransferSpeedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Transfer Speed", id: "main") {
            ContentView()
                .frame(minWidth: 760, minHeight: 640)
        }
        .defaultSize(width: 900, height: 720)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Lets `swift run` show a normal Dock app even without a bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

extension Color {
    static let brand = Color(red: 1, green: 140 / 255, blue: 0)
    static let readAccent = Color.blue
}

struct ContentView: View {
    enum Mode: Hashable {
        case copy, benchmark
    }

    @State private var mode = Mode.copy
    @State private var copyJob = CopyJob()
    @State private var benchmarkJob = BenchmarkJob()

    var body: some View {
        Group {
            switch mode {
            case .copy: CopyView(job: copyJob)
            case .benchmark: BenchmarkView(job: benchmarkJob)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $mode) {
                    Text("Copy").tag(Mode.copy)
                    Text("Benchmark").tag(Mode.benchmark)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                // Running both at once would skew each other's numbers.
                .disabled(copyJob.isRunning || benchmarkJob.isRunning)
            }
        }
        .tint(.brand)
    }
}
