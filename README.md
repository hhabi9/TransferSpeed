# Transfer Speed

Native macOS (SwiftUI) tool for measuring file transfer speed. Requires macOS 15+.

**Copy** — pick or drop files/folders and a destination. Copies them while showing live MB/s, a speed graph, progress, ETA, average and peak. Never overwrites: stops if an item with the same name already exists. Preserves permissions, timestamps, extended attributes and symlinks.

**Benchmark** — pick a drive (internal, USB, Thunderbolt, mounted SMB/AFP/NFS share) or any folder. Writes a 1–10 GB test file, flushes it to the device, reads it back, deletes it, and reports sequential write/read speed.

## How it measures

- Raw POSIX `read`/`write` in 8 MB chunks with `F_NOCACHE`, so the page cache in RAM doesn't inflate results.
- Benchmark write time includes `F_FULLFSYNC` (falls back to `fsync` on shares that lack it).
- Live speed is a 1-second sliding window; final numbers are total bytes ÷ total time.
- Speeds are decimal MB/s (1 MB = 1,000,000 bytes), like drive spec sheets and most disk tools.

## Install

Download the `.dmg` from [Releases](../../releases), open it, and drag **Transfer Speed** to Applications. Universal build: runs on Apple Silicon and Intel.

The app is ad-hoc signed, not notarized, so macOS blocks the first launch. Open it once, then go to **System Settings → Privacy & Security** and click **Open Anyway**.

## Build

```bash
./build.sh        # build/Transfer Speed.app
./build.sh dmg    # also build/TransferSpeed-<version>.dmg
```

With a **Developer ID Application** certificate in the keychain, the app and DMG are signed with it (hardened runtime, secure timestamp); otherwise they are signed ad-hoc. To also notarize and staple the DMG, store credentials once and pass the profile name:

```bash
xcrun notarytool store-credentials TransferSpeed --apple-id <apple-id> --team-id <team-id>
NOTARY_PROFILE=TransferSpeed ./build.sh dmg
```

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
