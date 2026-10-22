---
id: logmoji
version: 1.0
created: 2025-12-02
category: formatting
layer: 4
type: tool

chains_with:
  - sequential: "post-step completion hook"
depends_on: []
used_by:
  - sequential: "logs status after each step"

usage_stats:
  invocations: 0
---

# logmoji

Immediately return a single status line for the specific request.

Output format (exact):
```markdown
<emoji> - <short status message>
```

Example:
```markdown
🟢 - hooks activated: .hooks/pre-commit + .hooks/pre-push
```

Emoji selections are restricted to:
- 🔴 = failure
- 🟡 = pending, in progress, anything that is not a success or failure
- 🟢 = success

Rules:
- Return exactly one line, no headers, no bullets, no code fences.
- Pick one emoji by outcome and include a concise reason.
- If output text is provided by the user (terminal snippet, command result), summarize that result directly.
- Do not add extra explanation unless user explicitly asks for details.
