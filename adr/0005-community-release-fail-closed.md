# ADR 0005 — Free Community release and fail-closed commercial policy

- Status: Accepted
- Date: 2026-08-09

## Context

Pikafish code and NNUE have separate license obligations. Commercial use of official networks and Mac App Store distribution require explicit review. Accidental permissive release is a material risk.

## Decision

The default distribution is a free, open-source, Developer ID-signed, notarized Community build outside the Mac App Store. Commercial, paid and Mac App Store configurations are disabled in project schemes, scripts and CI, with negative tests. Release includes exact corresponding source, modifications, build instructions, GPL materials and the precise NNUE license.

## Consequences

The first release is intentionally constrained. Unblocking requires a new accepted legal/license ADR with written permission or validated alternative assets and a distribution review. This policy is engineering risk control, not legal advice.

## Revisit trigger

Receipt of written rights or adoption of replacement engine/network assets, followed by qualified review and a complete new release matrix.
