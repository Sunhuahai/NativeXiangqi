# ADR 0001 — AppKit-first native UI

- Status: Accepted
- Date: 2026-08-09

## Context

The application requires macOS documents, menus, undo, keyboard navigation, accessibility and predictable low-overhead windowing. No cross-platform target exists.

## Decision

Use AppKit for lifecycle, `NSDocument`, windows, split views, tables/outlines, commands, drag/drop and accessibility. Render the Xiangqi board in a custom `NSView` with Core Graphics. SwiftUI is limited to isolated settings and may not own game state.

## Consequences

Native behavior is direct and the product remains macOS-only. Board geometry, flipping and virtual accessibility require focused tests.

## Revisit trigger

Only measured rendering limitations or a concrete additional Apple-platform product decision.
