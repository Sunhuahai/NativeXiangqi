# 11. Codex 执行规范

## 1. 一次一张任务卡

```text
read AGENTS + active task + ADR/docs
inspect repo
state modules/facts/risks
add tests
implement smallest complete slice
run commands
inspect diff
write report
stop
```

不要一次要求完整 App。任务卡通常对应一个 PR。

## 2. 修改前

列出任务理解、模块、需验证事实、风险/冲突。可从 repo 得到的先检查，不重复询问。

## 3. 报告

`docs/task-reports/Txxx.md`：summary、files、decisions、commands/results、tests、measurements、source/license artifacts、limitations、out-of-scope、exact next task。

## 4. PR 粒度

- engine/NNUE update 独立；
- license/release policy 独立；
- rule bug 先 fixture；
- WXF corpus expected 需人工审查；
- 格式化/重命名/依赖升级不混功能。

## 5. 禁止

- 通用棋类框架；
- engine 作为规则 oracle；
- JSON/string UCI 直接传 UI；
- per-square view/FFI；
- `sleep` 修取消；
- unbounded logs/streams/cache；
- `@unchecked Sendable`/unsafe 扩散；
- Xcode build 下载资产；
- 用 env var 绕过 commercial/MAS；
- source archive 不可重建仍标完成；
- ambiguous WXF 强判结果。

## 6. 引擎更新

manifest → hash/source/license → build/help target → handshake → protocol tests → fixed benchmark → memory → corresponding source rebuild → release eligibility。失败保持旧版本。

## 7. 完成

编译成功不够。用户路径、失败、取消、资源、规则、分发 policy、测试、文档和 acceptance 均通过。
