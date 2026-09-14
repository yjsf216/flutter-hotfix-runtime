# Order example device checkpoint (2026-09-14)

## Android: verified

The existing authorized Android test app was updated without uninstalling or
clearing data. The order example used the custom arm64 AOT/DDM Engine and the
unified CLI-generated signed business-method patch.

- Initial launch rendered **Quantity: 2 / Total cents: 2400**.
- After first-frame health, the app downloaded `order-online-1` from the local
  development service; the displayed page stayed at 2400.
- A cold restart rendered **Quantity: 2 / Total cents: 2200**.
- Store state committed active/LKG `order-online-1`, null pending and zero failures.
- Server received `baseline_healthy → downloaded → patch_healthy` in order.
- APK signature and 16 KiB ZIP alignment passed; packaged AOT/Engine bytes matched
  the staged inputs exactly. Both before/after screenshots were visually inspected.

Private retained audit: `work/order-device.kEjasN` (not published).
Files include `order-android.apk`, `android-before.png`, `android-after.png`,
`android-first.log`, `android-second.log`, both state snapshots,
`android-evidence.json` and `server/reports.jsonl`.

The test reused the native test shell and its standard Flutter assets, not a
general-purpose native packaging command. No separate business project was edited.

## iOS: paused at the user's request

A development-signed app/IPA and matching signed order patch were generated.
The authorized iPhone was unavailable; **no order-example iOS device execution
or online behavior is claimed**. The user subsequently requested pausing iOS.

The private audit retains `order-ios-development.ipa`, `OrderRuntime.xcodeproj`,
`ios-online/`, `ios-patch/` and `ios-app.log`. Development profiles and test
manifests expire; inspect them before resuming. The embedded LAN endpoint is
development-only and may require a new baseline if the host address changes.
