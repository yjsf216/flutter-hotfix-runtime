# Contributing

This is an experimental Android/iOS hotfix runtime, not a drop-in production SDK.
Please open an issue describing a reproducible problem or a bounded proposal
before undertaking a major change. Never include signing keys, tokens, device
identifiers, private application code or private logs in a public issue.

For native-store changes, run `sh native/run_patch_store_io_check.sh`. For delivery
changes, run the HTTP regression described in `delivery/README.md` after setting
up the pinned Dart dependencies. State which checks you ran and which remain
unverified. Host checks are not a substitute for device evidence.

Do not weaken signature, baseline identity, path validation, durability or
fail-open recovery checks to make a test pass. New device operations must require
an explicitly selected, authorized device and remain scoped to the test app.

Contributions intentionally submitted for inclusion are offered under Apache-2.0
unless explicitly stated otherwise. Preserve third-party licensing and clearly
identify any imported code and its origin.
