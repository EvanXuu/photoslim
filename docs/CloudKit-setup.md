# CloudKit processed-item records

[Project README](../README.md) · [中文项目说明](../README.zh-CN.md)

PhotoSlim's local compression and recovery workflow does not require CloudKit. The optional ledger prevents a confirmed processed item from being selected again on another device using the same Photos/iCloud account.

## Data and identity

- Use the **private** database in `iCloud.local.codex.PhotoSlim`, zone `PhotoSlimProcessedAssets`.
- Match assets using PhotoKit's `PHCloudIdentifier.stringValue`, mapped to each device's local identifier. Never use a `PHAsset.localIdentifier` as a cross-device key, or infer a match from a filename, date, or dimensions.
- Record names are `asset-` plus a SHA-256 hash of the output cloud identifier. Repeated writes merge into one record.
- Only archived `committed` sessions create records. Local previews, failures, cancellation, and rollback do not.
- If Photos has not assigned an output cloud identifier yet, retain a durable local pending commit and retry after Photos changes, foregrounding, or a manual sync. If no verified iCloud account is available, ordinary local history remains the source for later backfill.
- Account-scoped checkpoints and engine state are isolated on sign-out/switch. An old account's outbox is never sent to another account.
- Source relationships that conflict remain ambiguous and do not exclude an unrelated source. The verified output can still be matched.

`ProcessedAsset` fields:

| Field | CloudKit type | Meaning |
| --- | --- | --- |
| `outputAssetKey` | String | Stable output Photos cloud identifier |
| `sourceAssetKey` | String, optional | Stable source identifier captured before deletion |
| `sourceAmbiguous` | Int64, optional | Boolean conflict flag; missing means false |
| `completedAt` | Date/Time | Earliest confirmed completion time |
| `status` | String | Must be `committed` |
| `recordVersion` | Int64 | Must be supported version `1` |

No media bytes, thumbnails, filenames, locations, or other media metadata are sent. This is not a media backup or a global deduplication service. Disabling sync keeps local task history; it does not delete records already stored in iCloud.

## iPhone: signed development build

1. Use a paid Apple Developer team with access to the CloudKit container. Register the existing app identifier `local.codex.PhotoSlim.iOS`; do not change bundle IDs for each build.
2. Open `PhotoSlim/PhotoSlim-iOS.xcodeproj`, select the team, and enable automatic signing. Check iCloud/CloudKit and Remote Notifications capabilities against `PhotoSlim/Resources/PhotoSlim-iOS.entitlements` and the background mode in Info.plist.
3. Register/associate the container for that team in Apple's developer tools. Sign into the same iCloud account on both test devices and enable iCloud Photos.
4. Keep `PhotoSlimCloudSyncConfigured` true only for a provisioned build. Install from Xcode onto a real iPhone, or use a properly signed simulator build for preliminary sync checks.
5. Create the record schema in the development environment using a signed test, then review/deploy the schema to production before distribution. Do not consider an unprovisioned Simulator ZIP a CloudKit test.

The SDK 27.1/27.2 project settings enable Duo's new arrangement API; SDK 27.0 builds keep the fallback. Runtime deployment remains iOS 17.

## macOS: signed CloudKit package

The default build script uses `PhotoSlim.entitlements` for local processing. It deliberately excludes restricted CloudKit/APNs entitlements from ad-hoc packages; otherwise macOS may kill the process before launch.

To opt in, provide a matching Apple signing identity and explicit app provisioning profile. The profile must authorize `local.codex.PhotoSlim` and `iCloud.local.codex.PhotoSlim`; a stable certificate alone does not authorize CloudKit.

~~~sh
env PHOTOSLIM_CLOUDKIT_ENABLED=1 \
    PHOTOSLIM_SIGNING_IDENTITY='Apple Development: YOUR NAME (TEAMID)' \
    PHOTOSLIM_PROVISIONING_PROFILE='/absolute/path/PhotoSlim.provisionprofile' \
    ./PhotoSlim/Scripts/build-app.sh
~~~

The script reads the signed profile's entitlements, validates the app/container identifiers, embeds the profile, and marks the package as CloudKit-configured. `PhotoSlim-CloudKit.entitlements` documents the capabilities; do not add these restricted entitlements to an ad-hoc signature. Check the actual profile/certificate relationship and launch the signed package before distributing it. Production profiles and CloudKit environment selection must be appropriate for the distribution method; notarization is separate.

## Acceptance checklist — not yet completed on this machine

- [ ] Same account, iPhone → Mac and Mac → iPhone: confirm a synthetic compression task, allow the output to sync through Photos, then verify the other device excludes that output using its own local identifier.
- [ ] Preview, failure, cancel, rollback: verify no shared processed record is added and originals stay untouched.
- [ ] Offline completion: local history succeeds without waiting for a network call; pending records upload after reconnecting, without duplicates.
- [ ] Delayed PhotoKit cloud mapping: pending output IDs eventually resolve after Photos sync rather than being permanently dropped.
- [ ] Conflicting writes: keep a single output record and never exclude an unrelated source.
- [ ] Account switching: account A's entries/outbox do not appear or upload under account B; switching back restores A's account-scoped checkpoint.
- [ ] Disabled/unavailable CloudKit: local scan, compression, review, termination, history, and session recovery remain usable.

This Mac currently has no valid Apple signing identity, and a live container has not been provisioned during this change. Unit tests cover ledger identity, version validation, conservative merging, persisted account isolation, and local-only startup, not Apple's service or two-device delivery.

References: [Apple CKSyncEngine](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5), [Apple's sync-engine sample](https://github.com/apple/sample-cloudkit-sync-engine), [Apple's Duo guidance](https://developer.apple.com/iphone-duo/).
