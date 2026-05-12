# `current/` — Consolidated Requirements Document

This folder holds the **single, current version of the final consolidated requirements document** for the AppMarket project. It is the synthesized, decision-ready view that aggregates all the individual requirement items from [`../items/`](../items/), framed by the context in [`../inputs/`](../inputs/).

## The canonical file

The consolidated document lives at:

```
current/requirements.md
```

(Companion HTML mirror — `requirements.html` — is generated alongside it. **Keep both in sync** on every update, mirroring the convention used in `inputs/investigation-application-marketplace-approach.{md,html}`.)

## Purpose

- One file, always representing the **latest agreed state** of the project's requirements.
- Used as the input to architecture decisions, sprint planning, and (eventually) implementation work on `main`.
- Cross-references items in [`../items/`](../items/) by their `REQ-NNN` identifiers so every consolidated paragraph is traceable.

## Update policy

- The consolidated document is **rewritten** (not appended) each time enough item-level changes accumulate to warrant a refresh.
- Each rewrite should bump a version stamp in the document header (`Version: vN — YYYY-MM-DD`) and summarize what changed compared to the previous version in a `## Changelog` section at the bottom.
- The act of overwriting is a deliberate moment of consolidation, not a continuous append — that's what individual item files are for.

## Adoption to `main`

When the user decides a version of this document is ready to be adopted:
1. The user explicitly requests the merge.
2. `current/requirements.md` (and its HTML mirror) is merged into `main` under `docs/design/project-functions.MD` (or another agreed path).
3. The merge commit message records the adopted version stamp.
