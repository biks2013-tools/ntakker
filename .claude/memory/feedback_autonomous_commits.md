---
name: Autonomous commits during plan execution
description: User wants Claude to commit autonomously without per-commit confirmation when executing a multi-task implementation plan; standing override of the "don't perform VC ops" rule for the duration of plan execution
type: feedback
originSessionId: 73c1cc53-422e-4ffb-b4f1-a9af5171b6d7
---
When executing a multi-task implementation plan (subagent-driven or otherwise), commit autonomously after each task's reviews pass — do NOT ask for per-commit confirmation. The user finds repeated commit prompts annoying.

**Why:** Standing instruction given on 2026-05-02 during plan-012 execution: "make the commit and continue, dont ask me again and again, commit any time you consider you have to and continue with next steps."

**How to apply:**
- Use the suggested commit message produced by the plan's task spec.
- Co-author trailer: `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.
- Pause for user input only when something genuinely needs a decision (failing reviews after revision loops, BLOCKED implementer status, plan defects discovered mid-execution that change scope).
- The general project rule "Don't perform any version control operation unless I explicitly request it" still applies for *ad-hoc* VC operations (push, force-push, branch deletions, history rewrites). The standing authorization here covers `git add` + `git commit` only, in the context of executing a written, approved plan.
