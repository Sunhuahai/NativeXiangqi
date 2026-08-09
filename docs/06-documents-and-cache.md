# 06. 文档、交换格式与分析缓存

## 1. `.xqgame` v1

版本化 JSON 或 package 的选择由 T040 用基准/原子写入需求决定；默认先用受限 JSON 单文件。字段：

```text
schemaVersion
documentID
created/modified metadata
initialFEN
ruleProfile { id, version/snapshot }
variationTree
currentNode (optional UI recovery)
annotations
result
extensions
```

engine analysis、window layout、helper path、cache key 不成为文档必要字段。

## 2. 读取与迁移

1. 检查 bytes/version/递归深度。
2. 后台 decode 到临时结构。
3. Rust 重建并验证每一步或规范状态。
4. 运行纯函数/事务式 migration。
5. 成功后 MainActor 原子安装。
6. 失败保留源文件和旧状态，报告 field/ply。

迁移必须有旧版 fixtures，不能先写回再验证。

## 3. 写出

- 从 Rust 获取不可变 document snapshot。
- 大文档后台编码，可取消。
- `NSDocument` 原子写入、autosave、version recovery。
- 文档修改更新 change count。
- partial/final analysis 与 UI layout 不改变 change count。
- autosave 不等待 helper/cache。

## 4. FEN/UCCI

- FEN import 可新建文档或显式替换当前起始局面；替换前确认。
- FEN export 指定当前局面或初始局面。
- UCCI import 为主线，逐步验证；失败报告准确 ply，整体事务回滚。
- UCCI export 默认当前主线/选中路径。
- 粘贴板输入有长度限制。
- XQF 不在 v1 写出；只读导入需独立安全任务。

## 5. Analysis cache

```text
Application Support/<BundleID>/AnalysisCache.sqlite3
```

system SQLite3、WAL、prepared statements、single actor：

```sql
CREATE TABLE analysis_entry (
  key BLOB PRIMARY KEY,
  engine_commit TEXT NOT NULL,
  network_hash BLOB NOT NULL,
  schema_version INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  last_accessed_at INTEGER NOT NULL,
  payload BLOB NOT NULL,
  payload_bytes INTEGER NOT NULL
);
CREATE INDEX analysis_lru ON analysis_entry(last_accessed_at);
```

cache key 包含 canonical position、判罚所需 history/profile、engine/network、preset、budget、output flags。

## 6. 容量与损坏

- 默认磁盘 256 MiB；选项 64/256/1024 MiB。
- memory cache ≤ 32 entries 且有 byte cap。
- partial info 不持久化。
- 写后异步 LRU，不在启动全表加载。
- corrupt DB 隔离重建；不影响文档。
- payload decode error 当 miss 并删除单项。
- schema migration transaction + fixtures。
