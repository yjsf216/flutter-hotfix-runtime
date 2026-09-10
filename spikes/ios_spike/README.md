# iOS device host

The initial device matrix now passes. See [device evidence](DEVICE_EVIDENCE.md)
for verified scope, artifacts, personal signing and the startup fixes. The
unsigned checkpoint below is historical, not the current signing status.

## Latest checkpoint: unsigned app built, awaiting signing-team choice

The Engine completed all 4,923 resumed Ninja actions successfully. The iOS
generator produced frozen baseline
`af10834c826cf54ce3c2d06ec1cab7eca1e22195b75ea246cd7b2f5c6dfa45e8`
and a one-method Widget DBC3 patch. The same frozen Kernel was also compiled to
Apple AOT assembly, then linked into an arm64 `App.framework`.

Retained audit: `work/ios-device.wrQCNc` (reuse this; do not regenerate keys or
the baseline while signing is pending). The generated Xcode project is
`work/ios-device.wrQCNc/HotfixRuntime.xcodeproj`; unsigned app is under
`build/Build/Products/Release-iphoneos/HotfixRuntime.app`. `unsigned-build.log`
ends in `BUILD SUCCEEDED`. The user has been asked which Developer Team to use.
No signing, installation or iOS patch execution has occurred yet.

This native host reuses the shared signed Flutter/DBC3 fixture. It does not run
Flutter's build scripts or replace the frozen baseline with a stock snapshot.
`main.m` and `create_project.rb` are development validation tooling, not a
production app. Only the user-authorized iPhone may be used for deployment.

Current authorized target: authorized iPhone, iPhone 6s, iOS 15.8.7,
UDID `IOS_DEVICE_UDID`.
`IOS_DEVICE_UDID` is a redacted placeholder, not a usable device ID. The USB
helper requires `HOTFIX_TEST_DEVICE` to explicitly select your authorized phone;
its `--self-check` performs no device access.
For this older device, use `xcdevice` / the installed libimobiledevice tools to
inspect connectivity; absence from `devicectl` is not proof of disconnection.

## Build prerequisites

1. `sh engine/build_ios_ddm.sh` builds the custom Release/AOT/DDM Engine and
   arm64 host snapshot generator from the already configured isolated checkout.
   Metal Toolchain is now installed. The actual Engine build has completed;
   `work/ios-engine-build.log` retains output including the initial missing
   `vpython3` failure, followed by the resumed build with the correct environment.
2. Produce the frozen iOS AOT baseline as assembly with this exact iOS generator,
   then link it as `App.framework/App`. This packaging step has passed;
   the Android ELF is not an iOS framework.
3. Stage `Flutter.framework` and `App.framework` in a task-owned directory.
   `App.framework` must contain the matching `flutter_assets` and framework
   bundle metadata (`io.flutter.flutter.app`). Never substitute a stock Engine.
4. Run `ruby spikes/ios_spike/create_project.rb STAGE OUTPUT.xcodeproj`.
   It uses the already installed `xcodeproj` gem and refuses to replace an
   existing project. Select the authorized development team when signing.

The project embeds both frameworks, compiles the shared native store into the
app, and preserves its seven FFI exports. All configurations explicitly enable
the development-only fixed case selector; do not distribute this test host.

## Startup contract

Default root: the OS-provided, canonicalized Documents directory + `hotfix`.
With `--hotfix-case baseline|valid|invalid-signature|wrong-baseline`, the root is
`Documents/hotfix-device/CASE`. No arbitrary intent/argument path is accepted.
Input files are `inbox/manifest.json` and `inbox/patch.bytecode`; durable state
is under `store`. An existing store is loaded even when the inbox is absent.

The shared fixture verifies the mounted Text and rasterized first frame before
committing health, then returns a result over `hotfix/runtime-smoke`. The host
saves it as `result.txt`. Automatic-mode `PASS` alone does not prove activation:
also require active/LKG `p1`, null pending state and the expected patch digest.
Negative cases must have null active/LKG and empty digests in fresh case roots.

Checks completed: `ruby spikes/ios_spike/check_project.rb` verifies generated
project structure; Ruby syntax and Objective-C syntax against the installed
Flutter iOS public headers. A subsequent unsigned iOS app link has passed.
Installation, rendering and device patch execution remain pending.
