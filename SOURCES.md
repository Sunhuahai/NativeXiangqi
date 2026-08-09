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

### T000 locked development evidence

- Selected release: Pikafish-2026-01-02
- Commit: ce0679e00ee196f7ba17f6ec18941b9a5036f8cf
- GitHub API source archive observed on 2026-08-09:
  - bytes: 436501
  - SHA-256: 48db60d32b056e33e84144aeee354082a4d15a5d6c930dc04f920e9b001cf904
- Upstream code terms: GPL version 3, preserved exactly in LICENSE and
  Engines/Pikafish/licenses/GPL-3.0.txt
- Apple Silicon build candidate: upstream make help lists ARCH=apple-silicon;
  selected command is make profile-build ARCH=apple-silicon COMP=clang
- Full make help evidence: Engines/Pikafish/configs/make-help-Pikafish-2026-01-02.txt

The official master-net asset observed on 2026-08-09 is pikafish.nnue, asset ID
483572672, 51,585,654 bytes, SHA-256
3cd15292bf8c979884262f57fc723959fc0dea43b4d8d544f88db5ceb2479e24.
Its permission evidence is locked to Networks commit
a238f8da2df269c28fec0e2bd2ca0ffd241f83fe and preserved exactly in
Engines/Pikafish/licenses/NETWORK-UPSTREAM-README.md. It forbids commercial use
without permission. The release tag is mutable, NativeXiangqi has no recorded written
commercial permission, and T000 bundles neither the network nor an engine helper.

## Xiangqi rules

- World Xiangqi Rules source page: https://www.wxf-xiangqi.org/index.php?Itemid=291&id=269&lang=en&option=com_content&view=article

## Rust

- Stable installer archive/toolchain status: https://forge.rust-lang.org/infra/archive-stable-version-installers.html

## Policy

T000 selects a pinned tag/commit only after checking the source's own build help on Apple Silicon. Release requires source archive, patch, build, executable and NNUE hashes, exact corresponding source and complete license texts. WXF behavior is tied to a preserved edition/snapshot. Commercial/store conclusions require qualified review.
