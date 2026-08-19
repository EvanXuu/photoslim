# PhotoSlim 0.2beta

PhotoSlim 0.2beta makes compression review-first: your original remains untouched until you have inspected and approved the generated result.

## Highlights

- Review compressed results locally before writing anything back to Photos.
- Open results in a zoomable detail view and hold the backslash key to compare the original under the pointer.
- Download up to five iCloud originals in parallel while compression continues.
- Re-encode ordinary `hvc1` HEVC videos when explicitly selected.
- Use AVAssetExportSession's automatic HEVC path by default, with an editable manual bitrate table for 1080p, 2160p, and 4320p at 30/60 fps.
- See the current media type in the native window title and the item count in its subtitle.
- Avoid speculative savings numbers; real savings appear only after compression and verification.
- Use an 8% default minimum real saving threshold for new or untouched legacy settings.

## Important notes

- The prebuilt app is ad-hoc signed and not notarized. macOS may show an unidentified developer warning.
- Dolby Vision, HDR, `hev1`, HEVC Alpha, and mixed-track media remain conservatively excluded.
- Start with a small, backed-up batch. This is an early alpha-quality release.

[中文更新日志](CHANGELOG.zh-CN.md) · [Full changelog](CHANGELOG.md)
