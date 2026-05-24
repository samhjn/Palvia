# Example: a prose-only skill

Some skills are pure methodology — no scripts, no custom tools, just
instructions the model follows when the skill is active. The minimum
authoring is two `fs.writeFile` calls (or one `scaffold` + one rewrite of
SKILL.md):

```
fs.mkdir('skills/code-review')
fs.writeFile('skills/code-review/SKILL.md', `---
name: Code Review
description: Walk a diff or PR with attention to correctness, edge cases, and code-style consistency.
iclaw:
  tags: [code-review, quality]
---
# Code Review

When asked to review a change:

1. Read the full diff first; resist commenting until you've seen the whole context.
2. Categorize each finding as bug / smell / nit and prioritize accordingly.
3. ...
`)
```

After authoring:

```
validate_skill(slug='code-review')   // expect ok: true
install_skill(name='Code Review')     // bind to current agent
```

The skill's body is now in the system prompt. There are no `skill_*` tools
because no `tools/<tool>.js` files exist — that's fine for prose-only skills.
