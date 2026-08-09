# Primary sources and verification policy

Baseline verification date: **2026-08-09**. Re-check before T000, every engine/network update, WXF implementation, and release. Use the locked source's documentation and exact license texts.

## Apple

- Native macOS development: https://developer.apple.com/macos/
- Embedding a helper tool in a sandboxed app: https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app
- App Sandbox: https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox
- Notarization: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- Developer Program License Agreement: https://developer.apple.com/support/terms/apple-developer-program-license-agreement/
- Upcoming Xcode/SDK requirements: https://developer.apple.com/news/upcoming-requirements/

## Pikafish

- Repository and code license: https://github.com/official-pikafish/Pikafish
- Networks and network license: https://github.com/official-pikafish/Networks
- UCI documentation: https://www.pikafish.com/wiki/index.php?title=UCI%E5%8D%8F%E8%AE%AE

## Xiangqi rules

- World Xiangqi Rules source page: https://www.wxf-xiangqi.org/index.php?Itemid=291&id=269&lang=en&option=com_content&view=article

## Rust

- Stable installer archive/toolchain status: https://forge.rust-lang.org/infra/archive-stable-version-installers.html

## Policy

T000 selects a pinned tag/commit only after checking the source's own build help on Apple Silicon. Release requires source archive, patch, build, executable and NNUE hashes, exact corresponding source and complete license texts. WXF behavior is tied to a preserved edition/snapshot. Commercial/store conclusions require qualified review.
