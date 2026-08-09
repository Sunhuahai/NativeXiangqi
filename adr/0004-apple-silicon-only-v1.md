# ADR 0004 — Apple Silicon-only v1

- Status: Accepted
- Date: 2026-08-09

## Context

A second architecture expands engine build targets, NNUE optimization, signing and performance matrices. The initial product targets modern Macs.

## Decision

Build v1 for arm64 only with minimum macOS 15. Do not create a Universal Binary.

## Consequences

Smaller artifacts and focused testing; Intel unsupported. Future Intel support requires a separate release artifact and benchmark matrix.

## Revisit trigger

Demonstrated demand plus maintained engine support and project resources.
