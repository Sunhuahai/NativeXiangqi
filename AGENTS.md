# AGENTS.md

## Mission

Build one native macOS application, `NativeXiangqi`, for local Chinese Chess play, game-record editing, analysis, and strong Pikafish-backed human-versus-engine play. This is a single-product repository. Do not add Go, a generic multi-game framework, a cross-platform UI layer, or speculative abstractions for unrelated games.

The product priorities, in order, are:

1. correct and recoverable user documents;
2. correct engine-independent Xiangqi legality and deterministic state transitions;
3. explicit, explainable rule-profile handling, especially repetition, long check, and long chase;
4. native macOS behavior and accessibility;
5. safe, cancellable, process-isolated Pikafish integration;
6. bounded memory, CPU, queues, logs, and caches;
7. reproducible builds, exact corresponding source, and fail-closed license/distribution policy.

## Source of truth and precedence

Before changing code, read in this order:

1. the active task card in `tasks/`;
2. accepted ADRs in `adr/`;
3. the relevant documents under `docs/`;
4. this file;
5. existing code and tests.

A lower item does not override a higher item. When requirements conflict, do not silently choose the convenient interpretation. Record the conflict in the task report, choose the safest reversible implementation that preserves user data and distribution restrictions, and stop scope expansion.

## Repository scope

The target repository converges on this shape:

```text
NativeXiangqi/
├── AGENTS.md
├── Makefile
├── NativeXiangqi.xcworkspace
├── App/NativeXiangqi/
├── Packages/
│   ├── XiangqiUI/
│   ├── XiangqiDocumentKit/
│   ├── PikafishKit/
│   └── XiangqiCoreBinary/
├── Rust/
│   ├── Cargo.toml
│   └── crates/
│       ├── xiangqi-core/
│       ├── xiangqi-io/
│       └── xiangqi-ffi/
├── Engines/Pikafish/
│   ├── manifests/
│   ├── configs/
│   ├── licenses/
│   └── corresponding-source/
├── Tests/
│   ├── Fixtures/
│   ├── EngineFakes/
│   └── Benchmarks/
├── scripts/
└── docs/
```

Do not create a package, protocol, service, or base class merely because it could be reused by another board game. Extract only after two concrete call sites demonstrate the same invariant.

## Non-negotiable architecture

- v1 is Apple Silicon only, with deployment target macOS 15.
- Use AppKit for the application lifecycle, documents, windows, menus, toolbars, split views, tables, outlines, drag and drop, undo, and accessibility.
- The board is a custom `NSView` rendered with Core Graphics. Do not introduce Catalyst, Electron, Flutter, Qt, React Native, SDL UI, a browser shell, or a cross-platform view abstraction.
- Swift owns macOS integration, presentation state, document coordination, process control, and SQLite access.
- Rust owns canonical Xiangqi state, legal move generation, apply/undo, check/mate/stalemate, repetition event history, hashes, compact variation trees, FEN/UCCI codecs, and WXF adjudication assigned by the active task.
- Swift must never maintain an independent authoritative board, legality, or adjudication state. Swift snapshots are immutable and disposable.
- Pikafish runs as a signed child executable. Never link Pikafish or its C++ runtime into the main app process.
- Pikafish is not the legality or tournament-rule oracle. Every engine move is revalidated by Rust, and engine evaluation never decides repetition responsibility.
- The application must remain fully usable for editing, browsing, saving, and recovery when Pikafish or its NNUE is missing, loading, stopped, incompatible, or crashed.
- No runtime network entitlement in v1. Xcode builds and archives must not download engines, networks, source archives, or dependencies.
- No third-party Swift package in v1 without an accepted ADR. Prefer Apple frameworks and system SQLite3.
- Every collection, cache, stream, queue, log, request table, parser allocation, and engine buffer has an explicit limit.

## Distribution policy is fail-closed

The default release track is a free, open-source, Developer ID-signed and notarized Community build distributed outside the Mac App Store.

Until an accepted legal/license ADR records all required evidence:

- commercial, paid, donation-gated, subscription, in-app-purchase, and bundled-paid-product builds remain disabled;
- Mac App Store schemes and submission automation remain disabled;
- release scripts must reject attempts to override these restrictions;
- official NNUE assets are used only within their exact permissions;
- the distributed helper must have exact corresponding source, patches, build instructions, checksums, licenses, and notices.

Do not weaken, bypass, rename, hide, or convert these gates into a casual environment variable. A change to this policy is a release/security change and must be reviewed independently. This engineering policy is conservative and does not replace qualified legal advice.

## Work discipline

- Execute exactly one task card at a time.
- Inspect the repository before assuming a file, target, scheme, option, protocol token, engine build target, or tool exists.
- Keep edits within the task's allowed scope. A necessary compile fix outside scope must be minimal and reported.
- Do not perform opportunistic refactors, mass renames, dependency upgrades, or formatting of unrelated files.
- Do not leave `TODO`, stub, fatal placeholder, fake success, or disabled assertion on a path declared complete by the task.
- Add or update tests in the same change as behavior.
- A task is incomplete until all mandated commands pass and its acceptance criteria are demonstrated.
- Use small, intention-revealing commits. Engine/NNUE updates and license changes are always isolated from feature work.
- Do not begin the next task after completing the current one.

## Swift and concurrency rules

- Compile in Swift 6 language mode with strict concurrency checking.
- AppKit types, `NSDocument`, window controllers, view models, and mutable presentation state are `@MainActor`.
- `PikafishSession`, cache access, and other mutable non-UI subsystems use dedicated actors or explicitly isolated synchronous components.
- `Process`, `FileHandle`, pipes, timers, and continuation ownership stay behind one actor boundary.
- Never block the main thread on process I/O, file I/O, SQLite, NNUE loading, hashing, record parsing, large serialization, or Rust work that can exceed one frame.
- Avoid `Task.detached`. When unavoidable, document ownership, priority, cancellation, and the actor hop back.
- Do not use `@unchecked Sendable` as a compiler escape hatch. Each use requires an accepted justification and focused test.
- Use typed errors and recovery actions. Do not use `fatalError`, production force unwraps, ignored errors, or empty `catch` blocks.
- Use `os.Logger` with privacy annotations. Do not log complete game records, comments, user paths, unrestricted engine output, or NNUE contents.
- UI consumption of engine updates is throttled. Raw engine output frequency must never determine render frequency.

## AppKit and UX rules

- Use `NSDocument` autosave, version restoration, recent documents, change counting, and `UndoManager`; do not invent a parallel document lifecycle.
- Use native commands and validation for New, Open, Save, Save As, Undo, Redo, move navigation, analysis, board flip, notation display, and inspector visibility.
- Board geometry is a pure tested value type derived from bounds and backing scale. Never assume one device pixel per point.
- Draw only invalidated regions. Cache immutable paths, glyph runs, fonts, shadows, and textures at the appropriate scale.
- Do not create one `NSView`, `CALayer`, observer, or task per square or piece.
- Keyboard navigation, VoiceOver, Reduce Motion, high contrast, and non-color candidate labels are release requirements, not polish.
- Red/black perspective and board flipping are presentation transforms only; canonical Rust coordinates never change.
- Engine failure must leave a clear, nonmodal recovery path and must never close or dirty the document.
- Analysis panes and overlays are derived UI. Hiding or clearing them must not modify the game record.
- Until the reviewed WXF adjudication corpus passes, label the relevant rule profile as “基础规则模式”; never imply full tournament adjudication.

## Xiangqi rules invariants

- Rust is the sole authority for palace restrictions, river restrictions, advisor movement, elephant eye, horse leg, rook rays, cannon screens, pawn direction, flying-general exposure, self-check, check, mate, and stalemate/困毙.
- `apply` followed by `undo` must restore canonical bytes, side to move, half/full move metadata, captures, repetition history, adjudication events, variation cursor, and hash exactly.
- Failed moves must not partially mutate state.
- Move generation must be testable against fixed perft fixtures and randomized apply/undo properties.
- Rules are selected by an explicit versioned profile stored in the document. Never silently reinterpret an old record under a newer WXF snapshot.
- Repetition cycle detection is separate from responsibility classification.
- Long check and long chase classification returns structured evidence: cycle boundaries, per-ply labels, targets, legal alternatives, responsible side, and applicable rule citation/snapshot.
- Ambiguous or unsupported cases remain explicitly ambiguous. Never guess a winner to make a fixture pass.
- Pikafish score, PV, or best move cannot override rules or adjudication.
- FEN and UCCI parsing enforce syntax, board, king/general count, side-to-move, coordinate, length, and allocation limits.
- XQF is not a v1 release blocker. Do not add a speculative writer or unsafe parser outside an approved task.

## Rust rules

- Use the stable toolchain pinned by `rust-toolchain.toml`.
- `unsafe` is forbidden outside `xiangqi-ffi` and narrowly reviewed platform glue.
- Panics never cross FFI. Public operations return typed status/error values.
- Prefer a compact 90-square representation, fixed arrays, bit sets, small vectors, arenas, and enums over reference-counted object graphs.
- No async runtime, ORM, general parser framework, or large dependency without an accepted ADR and measured need.
- Core rules, adjudication, and codecs must be testable without Swift, AppKit, Pikafish, or a network.
- Release configuration uses deterministic features, LTO, one codegen unit where justified, panic abort, and stripped symbols.
- Fuzz targets must have input and time limits; “does not crash” is insufficient if memory or CPU is unbounded.

## C ABI rules

- Expose one narrow versioned C ABI through `xiangqi-ffi`.
- Use opaque handles, fixed-width integers, explicitly represented POD structs, and caller-provided or owned buffers with documented release functions.
- Never expose Rust references, slices, trait objects, native enums without representation, callbacks, futures, or async runtimes across the ABI.
- Validate every pointer, length, enum discriminant, square, coordinate, and capacity at the boundary.
- Every allocation has exactly one owner and one matching release function.
- Provide ABI major/minor and capability queries. Swift must reject incompatible binaries with a recoverable diagnostic.
- Generate the public C header from one source of truth and fail CI when regeneration changes committed output.
- Prefer batched board snapshots and legal-destination arrays over per-square FFI calls.

## Pikafish integration rules

- The locked manifest is authoritative for repository, tag/commit, source archive hash, compiler/target, build command, executable hash, NNUE source/hash/size, code license, network license, and corresponding-source location.
- Never build release artifacts from an unpinned branch. Run the locked source's own `make help` before selecting a target; do not assume historical architecture target names remain valid.
- Launch through `Process.executableURL` with explicit argument arrays. Never invoke a shell.
- Perform the UCI handshake and discover options dynamically. Set only options actually advertised by the locked engine.
- Decode raw lines inside `PikafishKit`; UI code receives typed values only.
- Every search has a generation, deadline, cancellation path, bounded output, and one terminal `bestmove` or typed failure.
- Bound stdout/stderr line length, total buffered bytes, pending commands, PV length, diagnostic history, and restart attempts.
- Use `stop`, wait for a bounded terminal response, then terminate only as a fallback. Do not use arbitrary sleeps to resolve races.
- Default Hash is conservative, threads are limited, and Ponder is off. User presets map to a whitelist, not arbitrary command injection.
- Revalidate every `bestmove` in Rust before applying it. An illegal, missing, malformed, or late move is an engine failure; never choose another move silently.
- Score perspective conversion is explicit and tested. Preserve raw `cp`/`mate` data internally; do not mislabel units.
- Only validated final results enter the persistent cache. Partial `info` lines are ephemeral.
- Stop search when the relevant document closes, the app enters memory pressure, the device enters low-power conditions, or the user disables analysis.
- Default to one heavy engine process and explicit idle shutdown.

## Documents and storage rules

- Use a versioned native `.xqgame` document as the authoritative editable record.
- Store initial FEN, explicit rule profile/version, variation tree, annotations, metadata, and extension fields needed for forward compatibility.
- Preserve unknown extension fields on round trip when safe.
- FEN and UCCI are interchange formats, not substitutes for the full branching document.
- Large parsing and serialization must support cancellation and atomic state replacement. A failed import or migration never overwrites the source.
- Engine analysis, UI layout, and cache metadata are not required document content.
- Use system SQLite3 behind one `AnalysisCache` actor, WAL mode, prepared statements, schema versioning, and bounded LRU eviction.
- Cache keys include canonical position, move history needed by repetition/adjudication, rule profile, engine commit, NNUE hash, profile, budget, and output flags.
- Cache corruption is isolated and rebuilt. It must never prevent opening or saving a game.
- Autosave and close never wait for the engine or cache.

## Performance and memory rules

- Treat memory targets in `config/memory-budgets.json` as release gates, not claims.
- Record idle RSS before introducing engine integration and prevent regressions.
- Default UI analysis update frequency is 5 Hz; hard maximum is 10 Hz.
- Idle CPU must approach zero; no polling loop may wake the app continuously.
- On memory pressure: stop deep/continuous analysis, release long PV/chart data, clear app LRU, reduce future Hash/thread presets, then terminate the helper while preserving the document.
- Measure app and helper separately and combined. Verify the helper disappears and memory returns near the no-engine baseline after shutdown.
- Performance fixes require a reproducible benchmark and must not weaken legality, adjudication, cancellation, accessibility, document safety, or release gates.

## Security, signing, source, and licenses

- Keep App Sandbox and Hardened Runtime enabled.
- The embedded helper is nested, signed, and validated inside an archived application, not only in Debug build products.
- Never execute a user-selected binary or download executable code.
- Verify source, executable, configuration, and NNUE hashes before release use.
- Never commit signing identities, certificates, notary credentials, private keys, API tokens, paid assets, or developer-specific paths.
- Preserve GPLv3, AUTHORS, all third-party notices, exact modifications, build scripts, and exact corresponding source sufficient to rebuild the distributed helper.
- Preserve the exact NNUE license and do not infer commercial rights from the engine code license.
- Any engine/network update requires an isolated review of source, hashes, protocol compatibility, strength, performance, memory, corresponding source, and licenses.
- Diagnostics are user-triggered and redacted; they exclude full records and comments by default.

## Required command contract

The repository must converge on these noninteractive root commands:

```bash
make bootstrap
make format
make lint
make generate-ffi
make rust-build
make rust-test
make swift-test
make integration-test
make engine-smoke
make build
make benchmark
make verify-assets
make verify-source
make verify-release-policy
make verify-signing
make release-gate
make test
```

A task may introduce the command it owns. Once introduced, it must remain documented, deterministic, network-free unless explicitly designated as a vendor-fetch operation, and return nonzero on failure.

## Definition of done

For every task, create `docs/task-reports/Txxx.md` containing:

- summary and files changed;
- design decisions and conflicts;
- commands run with outcomes;
- tests added or changed;
- measurements and test hardware when applicable;
- source/license artifacts affected;
- known limitations and remaining risks;
- every out-of-scope edit;
- the exact next task, without starting it.

“Build succeeds” is never sufficient. Completion requires the task's user-visible path, failure paths, resource bounds, tests, documentation, distribution gates, and acceptance commands to pass.
