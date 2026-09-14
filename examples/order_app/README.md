# Order repair example

A separate Flutter project with data access (`order_repository.dart`), observable
state (`order_model.dart`), view/preview (`order_view.dart`) and a selected patchable
business library (`pricing.dart`). It never edits another business app.

The repository defaults to a deterministic asynchronous local data source, not a
real commerce HTTP backend. A caller can inject its own async fetch operation.
The update service remains the existing real HTTP delivery path.

The baseline intentionally charges shipping per item: two 1000-cent items with
200-cent shipping total **2400**. `fixes/pricing.dart` changes only the calculation
to charge shipping once: **2200**. Quantity changes exercise normal page state.
The native startup harness checks the mounted total and rasterized first frame
before committing patch health; this expectation is specific to this example.

## Prepare

Follow `engine/README.md` for the pinned custom Flutter/Dart builds. Then:

```sh
cd examples/order_app
flutter pub get
flutter test
flutter analyze
# Optional UI-only preview (does not test the native hotfix runtime):
flutter widget-preview start
```

Use Flutter 3.41.9 and the repository's resolved Dart source dependencies.
The runtime now has normal `package:patch_ir_spike/dbc3_dispatch.dart` imports;
legacy source paths remain compatibility exports. A stock Flutter Engine still
cannot execute these dynamic-module patches.

## Build a baseline and a repair

From the repository root, configure your local tools (do not commit secrets):

```sh
export DART_BIN=/path/to/flutter/bin/cache/dart-sdk/bin/dart
export FLUTTER_SDK=/path/to/flutter
export DART_SDK_SOURCE="$PWD/work/upstream/dart-sdk"
export GEN_SNAPSHOT="$PWD/work/upstream/flutter-engine-ddm/engine/src/out/hotfix_android_release_arm64/artifacts_arm64/gen_snapshot_arm64"
export HOTFIX_PUBLIC_KEY_FILE=/path/to/signing/public-key.txt

sh tool/hotfix release examples/order_app/hotfix.android.json work/order-base-android
sh tool/hotfix patch work/order-base-android examples/order_app/fixes/pricing.dart work/order-patch-android
sh tool/hotfix sign work/order-base-android work/order-patch-android /path/to/signing order-fix-1
```

For iOS use `hotfix.ios.json`, its iOS `gen_snapshot_arm64`, and new output folders.
An existing output directory is rejected; failed builds should use a fresh output
path when retried. Keep `lib/pricing.dart` as the baseline or edit only that file
on a repair branch. Changes to unrelated inputs are rejected before compilation.
Tests/fix samples outside `lib/` do not become patchable application libraries.

Release output contains `release/` (frozen compiler input/recipe), `project.json`
(configuration/input hashes), and `libapp.so` on Android or `snapshot.S` on iOS.
This is an archive of compiler outputs, not a complete source/SDK backup.
It currently records local project paths; keep the checkout and pinned dependencies.

**Native APK/IPA packaging is still separate.** Embed the Android AOT ELF or link
the iOS assembly into App.framework with the matching custom Engine and native
store. The host must pass its private patch/store paths to main, initialize the
iOS app base, and use matching app ID/version settings. Existing test hosts show
this contract, but this CLI does not automatically adapt arbitrary native plugins.

## Publish and serve (explicit, not automatic)

Set `updateOrigin` in the baseline JSON before building if online checks are
desired; the default is no network update service. Use an HTTPS origin, or
explicit `allowDevelopmentHttp: true` for local testing only.

```sh
sh tool/hotfix serve /path/to/storage /path/to/signing/public-key.txt
sh tool/hotfix publish https://patches.example.com work/order-patch-android/manifest.json work/order-patch-android/patch.bytecode
```

The server and publisher require `HOTFIX_PUBLISH_TOKEN`. See `delivery/README.md`
for limits and development HTTP opt-in. Generation/signing never publish by
themselves. Manifest keys and identity are verified against the frozen baseline
after signing. Reuse a signed envelope unchanged for upload retries.

Current checks: widget/model behavior, guarded project input changes, Android
AOT/iOS assembly builds, one-method DBC3 generation and signature verification.
The runtime's previous real host Engine regression also passes after packaging
changes. New order-example device installation and online delivery are not yet
claimed. Existing greeting-demo Android/iOS device evidence remains separate.
See [the precise checkpoint](EVIDENCE.md). External dependency source checkouts
must remain pinned; the project guard checks their version/configuration metadata,
not arbitrary edits inside every external dependency's source directory.

Compiler implementation changes alter its identity: create new baselines with
this tool version, and retain the exact old tool version for old release archives.
