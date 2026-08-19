# Changelog

[简体中文](CHANGELOG.zh-CN.md)

## [0.2beta] - 2026-08-19

PhotoSlim 0.2beta makes the compression flow review-first: originals remain untouched until the user has inspected and approved the generated results.

### New features

- **Review before writing**: Compressed results stay in a local review grid. Users can open a result, zoom in, compare it with the original under the pointer, and only then write the approved copy to Photos.
- **Parallel iCloud downloads**: Up to five originals can download at the same time while local compression continues.
- **`hvc1` HEVC re-encoding**: Ordinary `hvc1` HEVC videos can be explicitly selected for another HEVC pass. Dolby Vision, HDR, `hev1`, HEVC Alpha, and mixed tracks remain conservatively excluded.
- **Automatic video export**: AVAssetExportSession's automatic HEVC path is now the default. Manual mode exposes an editable bitrate table for 1080p, 2160p, and 4320p at 30 and 60 fps.
- **Native window context**: The window title shows the current media type and the subtitle shows the item count, without a duplicate title control in the toolbar.

### Improvements

- Removed speculative output-size and savings estimates from scanning, selection, and preflight. Real savings are recorded only after the output has been created and verified.
- The default minimum real saving threshold is now 8% for new or untouched legacy settings.
- iCloud items use the known original `dataSize` when Photos provides it; unknown sizes are not estimated.
- Incremental scanning, search, filters, sorting, pinning, list/grid views, session recovery, statistics, and task history are retained while the user-facing copy is simpler and less implementation-focused.

### Bug fixes

- Before/After keyboard comparison follows the item under the mouse pointer and no longer produces a key-beep when no text field is focused.
- Compressed results open in a zoomable detail view.
- Removed stacked legacy search/title controls that could leave a second visual treatment over the native macOS toolbar.

### Notes

- The prebuilt app is ad-hoc signed and not notarized. macOS may show an unidentified developer warning.
- New PhotoKit assets receive a new asset identifier and add date. Edit history and face/person relationships are not copied.
- Start with a small, backed-up batch. This is still an early alpha-quality release.

## [0.1.0-alpha.1] - 2026-08-10

The first public Alpha release for validating scanning, downloading, compression, review, and Photos deletion confirmation with small, backed-up libraries.

### New features

- Scanned the Apple Photos library and reduced later scan time with incremental indexing.
- Converted ordinary JPEG photos to HEIC and SDR H.264 or ordinary `hvc1` HEVC videos to HEVC.
- Downloaded up to five iCloud originals in parallel and showed separate download and compression progress.
- Provided local Before/After review before writing to Photos.
- Saved the task queue, processing ledger, statistics, and unfinished sessions across launches.

### Improvements

- Added manual video bitrate, keyframe, frame-reordering, and audio policies.
- Read real iCloud file sizes only after downloading the original.
- Added 100%–500% zoom, pinch-to-zoom, and panning in result details.
- Limited the backslash shortcut to the result under the pointer.

### Bug fixes

- Fixed key-beeps caused by Before/After comparison when no text field had focus.
- Fixed compressed results not opening in a zoomable detail view.
- Fixed grid and detail previews competing for the same keyboard event.

### Notes

- The prebuilt app was ad-hoc signed and not notarized.
- Dolby Vision, HDR, `hev1`, HEVC Alpha, and mixed tracks were excluded.
- The release was intended for small, backed-up test batches.

[0.2beta]: https://github.com/EvanXuu/photoslim/releases/tag/v0.2beta
[0.1.0-alpha.1]: https://github.com/EvanXuu/photoslim/releases/tag/v0.1.0-alpha.1
