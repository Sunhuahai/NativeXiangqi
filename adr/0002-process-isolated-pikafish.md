# ADR 0002 — Run Pikafish as a signed child process

- Status: Accepted
- Date: 2026-08-09

## Context

Pikafish is a command-line UCI engine with independent C++/NNUE memory and crash behavior. Linking it would couple the app to its ABI and lifetime without improving rule authority.

## Decision

Embed a pinned helper and NNUE, launch with Foundation `Process`, communicate through UCI, and isolate lifecycle/protocol state in `PikafishSession`. Rust revalidates every move.

## Consequences

Process exit reclaims memory and crashes do not corrupt documents. The project must solve nested signing, bounded pipes, exact source, licenses and archive tests.

## Revisit trigger

Only an official embedding API with equivalent isolation and a separately approved licensing architecture.
