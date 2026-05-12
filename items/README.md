# `items/` — Individual Requirement Items

This folder holds **one file per identified requirement**. Each file is a discrete, atomic statement of a single requirement, written so that it can be independently reviewed, refined, accepted, deferred, or rejected.

The items in this folder are the **atomic units** from which the consolidated document in [`../current/`](../current/) is assembled. Source material that *led to* the requirements lives in [`../inputs/`](../inputs/).

## Filename convention

Each file is named:

```
REQ-NNN-<topic>-<short-slug>.md
```

- `REQ-` — fixed prefix, makes items easy to grep.
- `NNN` — three-digit sequential identifier, zero-padded (`001`, `002`, ..., `099`, `100`, ...). Assigned at creation; **never reused**, even if the item is later deleted.
- `<topic>` — the topic classification (see taxonomy below). Lowercase, single word.
- `<short-slug>` — a 2–5-word kebab-case summary of the requirement.

### Examples

- `REQ-001-showcase-homepage-hero.md`
- `REQ-002-search-faceted-filters.md`
- `REQ-003-lifecycle-deprecation-banner.md`
- `REQ-004-auth-entra-id-sso.md`
- `REQ-005-artifact-non-code-support.md`

## Topic taxonomy

Use one of these topic slugs as the `<topic>` component. The list is intentionally short — refine only when an existing topic becomes overloaded.

| Topic | Scope |
|---|---|
| `showcase` | Homepage, hero pages, item pages, marketing-grade presentation |
| `discovery` | Search, faceted filters, categorization, tags, taxonomy |
| `onboarding` | First-time visitor experience, getting-started flows, item-usage docs |
| `lifecycle` | Submit / review / publish / version / deprecate workflows |
| `auth` | Authentication, SSO, identity, sessions, profile |
| `permissions` | Authorization, roles, ownership, edit rights |
| `artifact` | Artifact data model, supported types, fields, metadata |
| `submission` | Submission UX, manifest ingestion, validation, curation gate |
| `ratings` | Ratings, comments, feedback, moderation |
| `analytics` | Views, click-throughs, dashboards, owner reports |
| `integration` | External system links (GitHub / Azure DevOps / registries / docs sites) |
| `governance` | Stale-entry policy, ownership rotation, audit, retention |
| `platform` | Hosting, infra, deployment, observability, performance |
| `accessibility` | A11y, internationalization, responsive design |
| `security` | Data protection, secret handling, vulnerability response |

## File structure

Each item file should follow this template:

```markdown
---
id: REQ-NNN
topic: <topic>
status: draft | proposed | accepted | deferred | rejected | superseded
priority: must | should | could | wont
created: YYYY-MM-DD
updated: YYYY-MM-DD
sources:
  - inputs/<file>.md#<anchor-or-line>
supersedes: []          # other REQ-NNN ids this replaces
superseded_by: null     # set when this item is replaced
---

# REQ-NNN — <Short Title>

## Statement
<One paragraph stating the requirement in business language.>

## Rationale
<Why this matters. Tie back to the project's primary goals: Showcase / Discovery / Onboarding / Lifecycle.>

## Acceptance criteria
- [ ] <Testable condition 1>
- [ ] <Testable condition 2>

## Open questions
- <Anything still unresolved>

## Notes
<Optional — design sketches, alternative formulations, links to related items via [[REQ-NNN]].>
```

## Lifecycle of an item

```
draft  ──►  proposed  ──►  accepted  ──►  (consolidated into ../current/requirements.md)
   │            │
   ├──► deferred (parked, may resurface)
   ├──► rejected (closed, kept for traceability)
   └──► superseded (replaced; superseded_by points to the new id)
```

- Items are **never deleted** once they receive an `REQ-NNN` identifier — even rejected ones stay for traceability.
- Status transitions are recorded by updating the frontmatter, optionally with a `## Status history` section at the bottom.
- The consolidated document in `../current/` ingests only items at status `accepted`.

## Naming a brand-new item

1. Pick the next free `NNN` (check the highest existing number; do not reuse).
2. Pick the most appropriate topic from the taxonomy.
3. Write a 2–5-word kebab-case slug.
4. Create the file using the template above with `status: draft`.
