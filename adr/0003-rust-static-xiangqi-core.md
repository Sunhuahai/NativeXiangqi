# ADR 0003 — Rust static rules and adjudication core

- Status: Accepted
- Date: 2026-08-09

## Context

Legality, perft, repetition events, WXF adjudication, exact undo and codecs require deterministic behavior independent of the engine. Swift remains the owner of macOS integration.

## Decision

Implement `xiangqi-core`, `xiangqi-io`, and `xiangqi-ffi` in Rust. Build an arm64 static library/XCFramework with a narrow versioned C ABI. Rust owns the canonical game and rule-profile state.

## Consequences

FFI ownership and generated headers require strict tests. Swift cannot duplicate legality or let engine output override adjudication.

## Revisit trigger

A measured unsolved FFI bottleneck or unsupported Rust platform toolchain.
