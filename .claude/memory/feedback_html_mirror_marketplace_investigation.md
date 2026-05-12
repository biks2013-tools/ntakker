---
name: feedback-html-mirror-marketplace-investigation
description: The marketplace investigation document is maintained in both Markdown and HTML — any update to the .md file must be propagated to the .html mirror in the same edit.
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 4d7f0f84-de5e-43f6-a5ac-1beb7da0888f
---

The file `docs/reference/investigation-application-marketplace-approach.md` (in project `AppMarket`) is maintained as **two parallel artifacts**: the canonical Markdown file and a styled HTML mirror at `docs/reference/investigation-application-marketplace-approach.html`. Whenever the Markdown is updated, the HTML companion MUST be regenerated/edited to reflect the same content in the same session — never leave the two out of sync.

**Why:** The user explicitly requested an HTML version of the marketplace investigation document and asked that a note be kept to update the HTML every time the Markdown is updated. The HTML version exists for stakeholder readability (it can be opened in a browser without a Markdown viewer).

**How to apply:**
- Whenever editing `investigation-application-marketplace-approach.md`, also apply the equivalent change to `investigation-application-marketplace-approach.html` in the same task.
- Both files carry an explicit "Sync Notice" callout at the top — do not remove it.
- The HTML file uses self-contained inline CSS (no external assets); preserve that structure when editing.
- If the user adds *new* parallel-mirror requirements for other documents, save a separate feedback memory rather than expanding this one.
