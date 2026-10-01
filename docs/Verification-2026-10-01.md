# Verification — 2026-10-01

Scope: English/Simplified Chinese UI, SDK 27 build readiness, iPhone Duo adaptation, and the pending private CloudKit processed-item ledger. Existing uncommitted iOS/CloudKit work was carried into an isolated `codex/sdk27-english-duo` worktree; the original checkout was not reset or overwritten.

## Verified

- Swift 6.4, language mode 5, macOS SDK 27.0: complete test suite with `-warnings-as-errors`, **34 tests passed, none skipped**. This includes generated JPEG → HEIC and H.264 → HEVC encoding, localization coverage/interpolation, ledger identity/version/conflict/account isolation, local-only CloudKit startup, persistence, disk checks, and bitrate recommendations.
- macOS release `.app` and ZIP: built, strict code signature verified, ZIP extracted and signature verified again. Local-only ad-hoc package starts without restricted CloudKit entitlements.
- iOS SDK 27.1: universal arm64/x86_64 Simulator app built and ad-hoc signature verified. iPhone arm64 device target compiles without signing; this is not a device installation.
- iOS 27.0 iPhone 18 Pro and iOS 27.1 Duo isolated simulators: app launch succeeds after removing restricted entitlements from the local-only package.
- Duo native UI: English library, media/filter/more controls, selection capsule, settings, 8% safety threshold, and unavailable-sync explanation were inspected.
- Generated JPEGs were imported only into the isolated test simulator. Compression produced local review results (about 275–276 KB actual saving for the tested fixtures), result detail opened, and the native photo zoom action changed 100% → 200% → fit. Closed, book, and open device poses were exercised; book pose retained the relative zoom.
- A pending review task was restarted and returned to the review grid without auto-submitting. Task history was also inspected in English.
- Discarding that generated pending result returned to the library, retained its source fixture, and removed the task's temporary working directory.
- iOS semantic accent/status tokens adapt to appearance. Computed solid-background contrast: light amber on white/grouped background 5.29:1/4.74:1, dark amber on raised background 6.04:1, filled-action foreground 5.29:1 light and 6.60:1 dark. Success/danger token pairs exceed 5:1. These numbers do not assert a full-screen material/contrast audit.
- Packaging guards reject CloudKit opt-in without a signing identity/profile and reject an iPhone SDK passed to the Simulator packaging script. `git diff --check` and shell syntax checks pass.

## Not verified / required before shipping

- **iOS 27.0 final SDK build:** only Xcode 27.1 is installed; its iOS SDK is 27.1 beta. Running the app on an iOS 27.0 runtime is not the same as compiling against the final 27.0 SDK. The new Duo API is conditionally compiled and availability-guarded for fallback builds.
- **Live CloudKit:** no valid Apple signing identity or provisioned container is available on this Mac. Network delivery, APNs, production schema/profile validation, offline reconnect, and real iPhone/Mac account switching still require the [signed two-device checklist](CloudKit-setup.md).
- **Full UI/accessibility/device matrix:** native zoom actions were tested, not a full pinch/pan automation suite or a physical Duo test. Large Dynamic Type is covered by layout tests, not a complete screen-by-screen VoiceOver/contrast run.
- **Real libraries:** no create/delete operation was performed in the user's real Photos library. Simulator fixtures and generated temporary media are not a substitute for backed-up real-media metadata and iCloud acceptance testing.
- **Distribution:** packages are local/ad-hoc, not notarized or App Store-ready; Simulator archives cannot run on a real iPhone. Existing release/version numbers have not been promoted to a new public release.

## Reproduce

~~~sh
xcrun swift test --disable-sandbox --package-path PhotoSlim \
    --scratch-path /private/tmp/photoslim-sdk27-test -Xswiftc -warnings-as-errors
PhotoSlim/Scripts/build-app.sh
PhotoSlim/Scripts/build-ios-simulator-app.sh
~~~

Select a separate final Xcode 27 installation with `DEVELOPER_DIR` when verifying the final SDK. Keep minimum deployment targets at macOS 14 and iOS 17. Use isolated simulators and disposable, generated media for write/delete tests.
