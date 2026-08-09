# 09. 安全、签名、分发与许可证

## 1. Sandbox

App Sandbox + Hardened Runtime。helper 嵌入 bundle、嵌套签名。v1 无网络 entitlement，不执行用户选定二进制。

文档通过 `NSDocument`/system panels/security-scoped URLs。NNUE 和 helper 随发行资产提供。

## 2. Developer ID

1. Archive。
2. 验证 helper、NNUE、entitlements。
3. 从内到外签名。
4. codesign/spctl 验证。
5. notarytool。
6. staple。
7. clean account 测试真实 helper 与文档。

凭据不进仓库。

## 3. Supply chain

manifest 锁定：

- repo/tag/commit；
- source archive hash；
- build help/target/toolchain/flags；
- patch hashes；
- executable hash；
- NNUE URL/name/bytes/hash/license；
- corresponding-source archive/hash；
- licenses/notices。

普通 build/archive offline。engine/network 更新独立 PR。

## 4. Pikafish code

按锁定 source 的实际 GPL 文件处理。Community release 携带完整 license、AUTHORS、修改、build scripts 和 exact corresponding source，足以重建 distributed binary。source archive 的 hash 进入 release report。

## 5. NNUE

NNUE 许可独立于 engine code。不得从 GPL 推导 network 商业许可。T000/T050 保存精确文本并标记允许的用途。任何商业意图先取得书面许可或替换为通过棋力门的可商用 network。

## 6. Fail-closed release

默认：

- Community Developer ID: allowed after gates；
- commercial/paid/IAP/subscription/donation-gated bundle: false；
- Mac App Store: false。

release scripts/schemes/CI 必须 negative test。解锁要求 accepted legal ADR、书面许可或替代资产、GPL/store review 和新 release matrix。免费也不自动等于条款兼容。

## 7. 项目自有代码

保守方案由 T000 最终记录。计划建议 Community 仓库整体使用 `GPL-3.0-only`，或在法律审查后确定清晰的多许可边界。不得在未决时写模糊“all rights reserved”。

## 8. Input/diagnostics

- JSON/FEN/UCCI/UCI 均有长度/深度限制。
- user string 不进入 shell。
- bundle paths + manifest verification。
- diagnostics 用户显式导出，包含版本、manifest、bounded handshake/state events/resource summary。
- 默认排除完整棋局、注释、用户名路径、完整 PV/database。
