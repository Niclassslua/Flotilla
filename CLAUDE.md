# Flotilla — Claude Guide

This project's authoritative reference for architecture, conventions, and build workflows is **`AGENTS.md`** — read it first.

## Testing scope

Only write a UI test (`FlotillaUITests`) for something a human can't easily eyeball, or that's a stable behavioral contract. Don't write UI tests asserting on visual/styling details — background tints, padding, corner radius, colors, frame sizes chosen for looks. A human glances at a screenshot and knows instantly if those are wrong; a test asserting on them breaks on every intentional visual change and becomes pure maintenance overhead with no signal. Reserve UI tests for things that are easy to silently regress and hard to notice by eye: keyboard-shortcut wiring, focus/dismissal behavior, data flowing correctly into fields, multi-step interaction sequences, accessibility-identifier contracts other tests depend on.

See `AGENTS.md`'s "UI Tests" section for the rest of the testing conventions (when to run the suite, accessibility-identifier patterns, etc.).
