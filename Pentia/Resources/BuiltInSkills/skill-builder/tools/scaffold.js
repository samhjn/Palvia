const META = {
  name: "scaffold",
  description: "Scaffold a minimal valid skill package at /skills/<slug>/. Writes SKILL.md with the given name+description, plus empty tools/ and scripts/ directories. Refuses to overwrite an existing package — pick a fresh slug or fs.delete the old one first.",
  parameters: [
    { name: "slug",        type: "string", required: true,  description: "Directory slug (lowercase, hyphenated). Becomes /skills/<slug>/." },
    { name: "name",        type: "string", required: true,  description: "Human-readable skill name. Goes into SKILL.md frontmatter as `name`." },
    { name: "description", type: "string", required: true,  description: "One-line description. Goes into frontmatter as `description` (≤200 chars)." },
    { name: "tags",        type: "string", required: false, description: "Comma-separated English tags for search (e.g. 'utility,demo'). Optional." }
  ]
};

// Strict slug shape: must round-trip through SkillPackage.derivedSlug so the
// validator's slug_mismatch check passes.
const slug = (args.slug || "").trim();
if (!slug) {
  console.log("[Error] slug is required.");
} else if (!/^[a-z0-9]+(-[a-z0-9]+)*$/.test(slug)) {
  console.log(`[Error] slug '${slug}' must be lowercase, hyphenated alphanumerics (matching /^[a-z0-9]+(-[a-z0-9]+)*$/).`);
} else {
  const name = (args.name || "").trim();
  const description = (args.description || "").trim();
  if (!name) {
    console.log("[Error] name is required.");
  } else if (name.length > 64) {
    console.log(`[Error] name is ${name.length} characters; the validator's max is 64.`);
  } else if (!description) {
    console.log("[Error] description is required.");
  } else if (description.length > 200) {
    console.log(`[Error] description is ${description.length} characters; the validator's max is 200.`);
  } else {
    const dir = `skills/${slug}`;
    const skillMd = `${dir}/SKILL.md`;
    const exists = await fs.exists(skillMd);
    if (exists) {
      console.log(`[Error] /skills/${slug}/SKILL.md already exists. Pick a fresh slug or fs.delete('skills/${slug}', {recursive:true}) first.`);
    } else {
      await fs.mkdir(dir);
      await fs.mkdir(`${dir}/tools`);
      await fs.mkdir(`${dir}/scripts`);

      const tagsLine = args.tags
        ? `\niclaw:\n  tags: [${args.tags.split(',').map(t => t.trim()).filter(Boolean).join(', ')}]\n`
        : "\n";

      const body = [
        "---",
        `name: ${name}`,
        `description: ${description}${tagsLine}---`,
        "",
        `# ${name}`,
        "",
        "Document this skill's methodology here. Reference your tools by name",
        `(\`skill_${slug.replace(/-/g, "_")}_<tool>\`) and your scripts via`,
        `\`run_snippet skill:${name}:<script>\`.`,
        ""
      ].join("\n");
      await fs.writeFile(skillMd, body);

      const lines = [
        `Scaffolded /skills/${slug}/.`,
        "",
        "Next steps:",
        `1. Add tools — fs.writeFile('skills/${slug}/tools/<tool>.js', ...) with a top-level \`const META = {...}\` declaration. See skill-builder's references/example-tooled.md.`,
        `2. validate_skill(slug='${slug}') — confirm the package parses cleanly.`,
        `3. install_skill(name='${name}') — bind it to this agent.`
      ];
      console.log(lines.join("\n"));
    }
  }
}
