# Transfer Speed

Native macOS (SwiftUI) tool for measuring file transfer speed. Requires macOS 15+.

**Copy** — pick or drop files/folders and a destination. Copies them while showing live MB/s, a speed graph, progress, ETA, average and peak. Never overwrites: stops if an item with the same name already exists. Preserves permissions, timestamps, extended attributes and symlinks.

**Benchmark** — pick a drive (internal, USB, Thunderbolt, mounted SMB/AFP/NFS share) or any folder. Writes a 1–10 GB test file, flushes it to the device, reads it back, deletes it, and reports sequential write/read speed.

## How it measures

- Raw POSIX `read`/`write` in 8 MB chunks with `F_NOCACHE`, so the page cache in RAM doesn't inflate results.
- Benchmark write time includes `F_FULLFSYNC` (falls back to `fsync` on shares that lack it).
- Live speed is a 1-second sliding window; final numbers are total bytes ÷ total time.
- Speeds are decimal MB/s (1 MB = 1,000,000 bytes), like drive spec sheets and most disk tools.

## Build

```bash
./build.sh
```

Output: `build/Transfer Speed.app` (ad-hoc signed). Drag it to `/Applications`.

Other commands:

```bash
swift run          # run without bundling
swift test         # engine tests
```

## Layout

- `Sources/TransferSpeed/Engine.swift` — copy planner/executor, benchmark I/O, cancellation
- `Sources/TransferSpeed/Jobs.swift` — observable view models and speed sampling
- `Sources/TransferSpeed/*View.swift`, `Components.swift` — UI
- `scripts/make-icon.swift` — renders the app icon

## License

MIT — see [LICENSE](LICENSE).
