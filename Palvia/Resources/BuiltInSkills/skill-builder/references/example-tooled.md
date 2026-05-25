# Example: a skill with one tool and one script

This walks through the full structure: frontmatter, body, a `tools/*.js`
function-call tool with typed parameters, and a `scripts/*.js` snippet.

## Directory layout

```
skills/greeter/
├── SKILL.md
├── tools/
│   └── greet.js
└── scripts/
    └── format_name.js
```

## SKILL.md

```markdown
---
name: Greeter
description: Greet users by name with optional formality. Demonstrates the canonical authoring pattern.
palvia:
  version: "1.0"
  tags: [demo, authoring]
---
# Greeter

Use this skill when the user asks for a greeting. The custom tool
`skill_greeter_greet` does the actual work; the `format_name` script
canonicalizes input names and is reused by the tool.

- `skill_greeter_greet(name, formal?)` — produce the greeting.
- `run_snippet skill:Greeter:format_name` — title-case and trim a name.
```

The frontmatter has exactly two **required** fields: `name` and `description`.
Names ≤ 64 chars, descriptions ≤ 200 chars. The `palvia:` block holds
Palvia-specific extras (tags, optional `slash:` slug override, configuration
schemas).

## tools/greet.js — the canonical META shape

```javascript
const META = {
  name: "greet",
  description: "Greet a user by name. Set formal=true for 'Good day, ...' instead of 'Hi, ...'.",
  parameters: [
    { name: "name",   type: "string",  required: true,  description: "The person to greet." },
    { name: "formal", type: "boolean", required: false, description: "Use the formal greeting." }
  ]
};

const cleaned = args.name.trim();
const greeting = args.formal ? `Good day, ${cleaned}.` : `Hi, ${cleaned}!`;
console.log(greeting);
```

Validator rules for `META`:

- `name` must match `[a-zA-Z_][a-zA-Z0-9_]*` (it becomes part of
  `skill_<slug>_<name>`).
- `description` should be ≥ 10 chars (warning below that — the model can't
  pick a vague tool reliably).
- `parameters[i].type` ∈ `{string, number, boolean, array, object}`. Typos
  produce a `bad_param_type` error with a "did you mean...?" suggestion.
- Duplicate parameter names are a warning; the parser keeps the first.

The body that follows the META declaration is what runs. It has these
globals:

- `args` — the parameter object the LLM sent.
- `fs` — the file system bridge (per-agent files + the `/skills/` mount).
- `apple` — Apple ecosystem APIs (HealthKit, Calendar, etc., subject to
  per-agent permissions).
- `fetch` — XHR-backed HTTP polyfill.
- `console.log` — captured and returned to the LLM as the tool's result.

## scripts/format_name.js — the snippet shape

```javascript
// Trim and title-case a person's name.

const raw = args.name || "";
const parts = raw.trim().split(/\s+/).filter(Boolean);
const titled = parts.map(p => p[0].toUpperCase() + p.slice(1).toLowerCase()).join(" ");
console.log(titled);
```

The first-line comment is the script's description (shown next to its name in
the system prompt). Scripts have the same JS environment as tools but no
typed parameters — they receive whatever the caller passed via `run_snippet`.

## Localization (optional)

Drop overlay files alongside the canonical:

- `SKILL.zh-Hans.md` — partial frontmatter (`display_name`, `description`)
  and a localized body.
- `tools/greet.zh-Hans.json` — localized `description` and per-parameter
  `description`s. Structural fields (name, type, required) stay English.
- `scripts/format_name.zh-Hans.txt` — single-line localized description.

`SkillPackage.parse` picks the best overlay against
`Bundle.main.preferredLocalizations` automatically. Skills without overlays
fall back to the canonical files.
