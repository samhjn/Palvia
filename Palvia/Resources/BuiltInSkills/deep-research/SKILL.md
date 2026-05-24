---
name: Deep Research
description: Systematic research methodology with source evaluation and synthesis
iclaw:
  version: "1.0"
  tags: [research, analysis, methodology]
---
# Deep Research Skill

When asked to research a topic, follow this methodology:

## Research Tools (in order of preference)

1. **Browser tools** (primary — most reliable for web research):
   - `browser_navigate(url:)` → open a URL in the in-app browser
   - `browser_get_page_info(include_content: true)` → read page text, links, and interactive elements
   - `browser_extract(selector:)` → extract specific elements (headlines, article bodies, etc.)
   - **Search strategy**: navigate to `https://www.google.com/search?q=YOUR+QUERY` to find sources, then visit promising results
2. **`fetch_and_extract`** (quick plain-text fetch — may fail due to sandbox network restrictions; if it returns HTTP 0 or network errors, switch to browser tools immediately)
3. **Post-processing scripts** (use `run_snippet` to execute):
   - `extract_links` — parse HTML to extract follow-up URLs for deeper investigation
   - `summarize_text` — condense long text into key points ranked by importance

## Process
1. **Decompose** the question into 2–5 focused sub-questions
2. **Search** — start with a search engine query via browser, then visit the most promising results
3. **Gather** — read each source page with `browser_get_page_info`; use `browser_extract` for specific content; follow links for deeper investigation
4. **Evaluate** — assess source credibility (official docs > research papers > established news > blogs), recency, and potential biases
5. **Synthesize** — organize findings into a coherent analysis, cross-referencing multiple sources
6. **Cite** — reference every key claim to its source URL with a confidence level (High / Medium / Low)

## Iterative Deepening
- After the first pass, identify gaps or conflicting information
- Search for additional sources to fill gaps or resolve conflicts
- Stop when key claims have 2–3 corroborating sources, or when additional sources add no new information

## Output Format
- **Executive Summary** — 2–3 sentence overview of key findings
- **Findings** — organized by sub-topic, each with inline source citations
- **Source Table** — list of sources used with credibility rating (High / Medium / Low)
- **Uncertainties** — flag conflicting information and knowledge gaps
- **Conclusions** — actionable takeaways

## Guidelines
- Prefer primary sources (official docs, research papers, raw data) over secondary (news articles, blog posts)
- Note when information might be outdated — check publication dates
- Distinguish clearly between established facts, expert opinions, and speculation
- When a tool fails, switch to an alternative immediately — do not retry the same failing tool
- Save key findings to MEMORY.md for future reference
