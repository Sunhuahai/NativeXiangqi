# XiangqiCoreBinary

This local package is the ownership-safe Swift surface for the T010 Rust C ABI.

`Artifacts/XiangqiCoreFFI.xcframework` is generated and intentionally ignored by Git. A clean
checkout must use the root commands so it is staged before SwiftPM or Xcode resolves this package:

```bash
make rust-build   # stages Release after building both configurations
make swift-test   # stages Debug before Swift package tests
make build        # stages Release before the native app build
```

The artifact script uses the checked-in ABI manifest/header and Cargo `--locked --offline`; it does
not fetch source, packages, engines, networks, or executables.
