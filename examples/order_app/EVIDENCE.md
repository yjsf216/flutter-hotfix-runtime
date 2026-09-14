# Project CLI checkpoint (2026-09-14)

Completed without modifying another business project or operating a device:

- Order view/model widget tests: async load, quantity change and the intentional
  baseline 2400-cent result; repair function produces 2200/3200 cents.
- Flutter analysis: no issues.
- Project input guards: unrelated Dart, new/deleted files, native configuration,
  declared resources and dependency metadata changes are rejected.
- Android CLI baseline: arm64 ELF generated with one automatic patch point.
- iOS CLI baseline: AOT assembly generated with one automatic patch point.
- Both CLI patches: one changed function, zero added private helpers; both signed
  and verified against their own frozen baseline/trust anchor.
- A changed function signature was rejected with an incompatible Kernel error.
- `serve` / `publish`: both signed outputs accepted through the unified CLI.
- Existing real host Flutter AOT Engine baseline/patch/negative matrix passed
  after moving runtime implementations into `lib/` and preserving compatibility
  exports. HTTP delivery regression and CLI analysis passed.

Private local audit directory: `work/project-cli.ibUtWy` (not distributed).
Successful archives are `android-v4/` and `ios-v2/`; associated patch directories
are `android-patch/` and `ios-patch/`. Earlier directories/logs retain failed
integration attempts, not successful baselines. `host-regression.log` records
the old greeting-fixture Engine matrix, **not order-example device execution**.

Still unverified for this new example: APK/IPA packaging, physical-device order
rendering/repair, and the order example's online two-start sequence. The earlier
greeting-demo device delivery evidence is independent. No App Store acceptance
or general multi-library compatibility is claimed.
