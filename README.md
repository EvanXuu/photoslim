# PhotoSlim

PhotoSlim is a native macOS app for reducing the size of an Apple Photos library while keeping the original asset safe until you approve the result.

> **0.2beta** — An early release for testing with small, backed-up batches. Do not start with the only copy of important media. The downloadable app is ad-hoc signed and not notarized, so macOS may show an unidentified developer warning.

[简体中文](README.zh-CN.md) · [Releases](https://github.com/EvanXuu/photoslim/releases) · [Product requirements](PRD-PhotoSlim.md) · [Design system](PhotoSlim/DESIGN_SYSTEM.md)

## What it does

- Converts ordinary JPEG photos to HEIC and SDR H.264 videos to HEVC.
- Allows ordinary `hvc1` HEVC videos to be re-encoded when you explicitly include them.
- Uses AVAssetExportSession's automatic HEVC path by default; detailed settings expose a manual bitrate table when you need more control.
- Reads only the size that Photos reports for an original resource. Unknown iCloud sizes are left blank instead of being guessed.
- Downloads up to five iCloud originals at once and overlaps downloading with local compression.
- Shows the compressed result locally before anything is written back to Photos.
- Lets you open a result for detailed viewing and hold the backslash key to compare the original under the mouse pointer.
- Writes the approved copy first, verifies it, and only then asks Photos to move the original to Recently Deleted.

## 0.2beta highlights

### New

- **Review before writing**: Compressed results stay in a local review grid. Users can open a result, zoom in, compare it with the original under the pointer, and only then write the approved copy to Photos.
- **Parallel iCloud downloads**: Up to five originals can download at the same time while local compression continues.
- **`hvc1` HEVC re-encoding**: Ordinary `hvc1` HEVC videos can be explicitly selected for another HEVC pass. Dolby Vision, HDR, `hev1`, HEVC Alpha, and mixed tracks remain conservatively excluded.
- **Automatic video export**: AVAssetExportSession's automatic HEVC path is now the default. Manual mode exposes an editable bitrate table for 1080p, 2160p, and 4320p at 30 and 60 fps.
- **Native window context**: The window title shows the current media type and the subtitle shows the item count, without an extra title bubble in the toolbar.

### Improvements

- Scan and selection no longer show speculative output-size or savings estimates. Real savings are recorded only after a real output has been produced and verified.
- The safety threshold defaults to 8% for new or untouched legacy settings.
- Incremental library scans, search, filters, sorting, pinning, list/grid views, queue recovery, statistics, and task history are preserved across sessions.
- User-facing messages describe the action, risk, and next step without exposing implementation details.

### Fixes

- Before/After keyboard comparison follows the item under the pointer and no longer sends a key-beep when no text field is focused.
- Compressed results open in a zoomable detail view.
- Search, title, and toolbar presentation use one native macOS treatment instead of stacked legacy controls.

## Safe workflow

1. Select assets.
2. Check local space, download up to five iCloud originals, compress, and verify the files.
3. Review the generated results locally. You may undo and clean up, or approve the write.
4. PhotoSlim creates and verifies the Photos copy.
5. Photos asks for confirmation before the original is moved to Recently Deleted.

PhotoSlim does not edit the `.photoslibrary` package directly. It uses public PhotoKit, ImageIO, AVFoundation, and VideoToolbox APIs. The original remains untouched during scanning, downloading, compression, and review.

## Supported scope

| Input | Output | Status in 0.2beta |
| --- | --- | --- |
| Ordinary JPEG | HEIC | Supported; dimensions and decodability are verified |
| SDR H.264 video | HEVC | Supported; automatic export is the default |
| Ordinary `hvc1` HEVC video | HEVC | Supported as an explicit re-encode option |
| `hev1`, Dolby Vision, HDR, HEVC Alpha, mixed tracks | — | Conservatively excluded |
| iCloud video with unknown encoding | — | Encoding is confirmed after the original is downloaded |

PhotoSlim copies and verifies the metadata that PhotoKit exposes for the new asset, including capture date, location, favorite state, hidden state, and ordinary album membership where supported. A newly created Photos asset necessarily receives a new asset identifier and add date; edit history and face/person relationships are not copied.

## Download and install

1. Download `PhotoSlim-0.2beta-macos.zip` from the [0.2beta release](https://github.com/EvanXuu/photoslim/releases/tag/v0.2beta).
2. Unzip it and move `PhotoSlim.app` to `/Applications`.
3. Grant Photos access on first launch and begin with a small test batch.

The prebuilt app is ad-hoc signed and not notarized. If macOS blocks the first launch, use **Open** from Finder's context menu after checking that the package came from this repository. A stable Apple Development or Developer ID signature is required to preserve Photos permission across binary updates; keeping the same bundle identifier alone is not sufficient for TCC identity.

## Requirements

- macOS 14 or later.
- Permission to read and add to the Apple Photos library.
- Enough local space for selected iCloud originals, temporary outputs, and the safety margin.
- Xcode Command Line Tools and a Swift 6 toolchain for source builds.

## Build and test from source

Debug build:

~~~
xcrun swift build --disable-sandbox --package-path PhotoSlim --scratch-path /private/tmp/photoslim-build
~~~

Tests:

~~~
xcrun swift test --disable-sandbox --package-path PhotoSlim --scratch-path /private/tmp/photoslim-test-build
~~~

Build a portable app and ZIP:

~~~
PhotoSlim/Scripts/build-app.sh
~~~

The default output is `PhotoSlim/build/PhotoSlim.app` and `PhotoSlim/build/PhotoSlim.app.zip`. To use a stable signing identity, set `PHOTOSLIM_SIGNING_IDENTITY` before running the script.

## Project structure

~~~
PhotoSlim/
|-- Sources/PhotoSlim/
|   |-- App/       App model, recovery, and task state
|   |-- Models/    Assets, filters, settings, sessions, and statistics
|   |-- Services/  PhotoKit, compression, disk checks, and persistence
|   |-- Theme/     Colors, spacing, and reusable styles
|   `-- Views/     Browser, task, review, queue, statistics, and history UI
|-- Tests/         Pure logic and generated-media encoding tests
|-- Resources/     Info.plist, entitlements, and app icon
`-- Scripts/       App packaging and icon generation
~~~

Real PhotoKit create/delete flows are not run by automated tests because they would modify a user's library. Tests cover pure logic, persistence, and generated temporary media instead.

## Privacy and license

PhotoSlim has no telemetry or cloud service. Media processing happens locally; Photos and iCloud may perform their own network operations. This repository currently has no open-source license, so the source is available for review but remains all rights reserved by default.
