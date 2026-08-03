# ADR 0001: Thin native frontends

- Status: Accepted
- Date: 2026-08-03

## Context

VolEq is macOS-first, with possible Linux and Windows editions later. Its UI is
small, while audio capture, permissions, lifecycle integration, packaging, and
accessibility are inherently platform-specific. A shared UI framework would
reduce some view duplication but would add runtime and distribution overhead
without removing most platform work.

## Decision

Each supported desktop platform will use a thin native frontend:

- macOS uses SwiftUI with focused AppKit integration.
- Linux and Windows will select native toolkits when their supported targets
  are defined.

Portable packages own DSP, presets, and platform-neutral product concepts.
Platform adapters own native audio integration. Frontends consume a small
UI-facing contract for commands, observable runtime state, capture targets,
settings, and user-facing status; they do not own DSP behavior or raw audio
lifecycle logic. Future platform contracts may add explicit capability and
structured-failure values when a second implementation establishes those
requirements.

The macOS application will not be rewritten in anticipation of platforms that
do not yet exist. A binary cross-platform interface will be considered only
when a second implementation provides concrete interoperability requirements.

## Consequences

- The application retains native controls, accessibility, system integration,
  startup behavior, and low UI overhead.
- Layout and interaction code will be implemented and tested per platform.
- Product terminology and behavior must remain consistent even where native
  presentation differs.
- Linux toolkit selection remains intentionally deferred until its desktop and
  distribution targets are known.

## Reconsideration

Re-evaluate a common UI framework only if measured duplication becomes a
material delivery cost and a candidate meets package-size, memory, launch-time,
accessibility, system-integration, visual-fit, and licensing requirements on
every supported platform.

## Related documentation

- [Architecture](../ARCHITECTURE.md)
- [Roadmap](../ROADMAP.md)
