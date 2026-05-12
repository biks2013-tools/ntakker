# `inputs/` — Raw Input Material

This folder holds **raw source material** that informs the requirements: emails, meeting transcripts, brainstorming notes, research/investigation documents, stakeholder feedback, screenshots of competing products, and any other artifact that contributes to understanding *what* the marketplace should be.

## What belongs here

- **Investigation & research documents** (e.g., comparative landscape studies, vendor evaluations).
- **Email threads** — converted to Markdown when possible, with a short header noting `From / To / Date / Subject`.
- **Meeting transcripts** — verbatim or summarized, with a header noting `Date / Participants / Topic`.
- **Stakeholder interviews** — Q&A or narrative notes.
- **Reference materials** — screenshots, slide excerpts, links to external articles or videos.
- **Brainstorming dumps** — free-form ideas, before they're refined into requirements.

## What does NOT belong here

- **Identified, distinct requirements** → those live in [`../items/`](../items/) as individual files.
- **The consolidated requirements document** → that lives in [`../current/`](../current/).

## Naming convention

Keep filenames descriptive and dated when relevant:
- `YYYY-MM-DD-<short-topic>.md` for time-bound material (emails, transcripts).
- `<topic-slug>.md` for evergreen reference material (investigations, comparative studies).

## Lifecycle

Input material is **append-only** once added — do not edit or delete prior inputs, because requirements traceability depends on being able to point back at the source. If an input is superseded, add a new file; do not rewrite the old one.
