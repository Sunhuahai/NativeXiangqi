Review the completed NativeXiangqi task as a strict maintainer. Read `AGENTS.md`, the task, docs/ADRs, diff, tests and report.

Prioritize:
- data loss or migration overwrite;
- illegal base moves, perft/hash/undo defects;
- Swift/Rust duplicate legality/adjudication state;
- Pikafish used as a rule oracle;
- WXF cycle/responsibility mistakes or ambiguous forced outcomes;
- FFI ownership/panic;
- actor cancellation/stale-generation races;
- unbounded UCI/output/PV/cache;
- score perspective errors;
- missing exact source/patch/build/NNUE license evidence;
- commercial/Mac App Store gates made bypassable;
- sleep-based tests or fake success.

Return severity-ordered findings with exact file/line and fixes. If no blocker, state verified acceptance evidence.
