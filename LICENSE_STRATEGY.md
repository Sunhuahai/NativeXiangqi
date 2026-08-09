# License strategy

This is a conservative engineering policy, not legal advice. T000 and every engine/network update must verify the exact included texts and permissions.

## Repository-owned code

T000 selects GPL-3.0-only for repository-owned code and preserves the complete terms in root LICENSE. A different boundary requires an accepted legal/license ADR before code is relicensed.

## Pikafish code

Treat the pinned source according to its exact GPLv3 materials. Distribution must include the license, AUTHORS/notices, modifications, build scripts and exact corresponding source sufficient to rebuild the distributed helper.

## NNUE

The network has a separate license/permission. Record source, filename, bytes, SHA-256 and complete license. Do not infer network commercial rights from the engine code license.

## Default release track

Allowed after technical gates:

- free/open-source Community build;
- Developer ID signing and notarization;
- distribution outside the Mac App Store.

Disabled until a later accepted legal/license ADR:

- commercial or paid distribution;
- IAP, subscription or donation-gated bundle;
- Mac App Store.

Unblocking requires written permission or a validated alternative network/engine, plus GPL/store distribution review.

## Release materials

Include project license, GPLv3, AUTHORS, modifications, exact source archive, build instructions, source/executable/network hashes, network license and all third-party notices. No task may weaken or summarize away these obligations.
