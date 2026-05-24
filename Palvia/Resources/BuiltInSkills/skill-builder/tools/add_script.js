const META = {
  name: "add_script",
  description: "Add a run_snippet-callable script to an existing skill package. Generates scripts/<script_name>.js with your description as the first-line comment and a TODO body. Scripts have no typed parameters — they receive whatever args the caller passes via run_snippet.",
  parameters: [
    { name: "slug",        type: "string", required: true,  description: "Slug of the target skill package under /skills/." },
    { name: "script_name", type: "string", required: true,  description: "Script name (must match /[a-zA-Z_][a-zA-Z0-9_]*/). Used in run_snippet skill:<skill name>:<script_name>." },
    { name: "description", type: "string", required: true,  description: "Single-line description; becomes the first-line comment that surfaces in the skill's scripts list." }
  ]
};

const slug = (args.slug || "").trim();
const scriptName = (args.script_name || "").trim();
const description = (args.description || "").trim();

let err = null;
if (!slug) {
  err = "[Error] slug is required.";
} else if (!/^[a-z0-9]+(-[a-z0-9]+)*$/.test(slug)) {
  err = `[Error] slug '${slug}' must match /^[a-z0-9]+(-[a-z0-9]+)*$/.`;
} else if (!scriptName) {
  err = "[Error] script_name is required.";
} else if (!/^[a-zA-Z_][a-zA-Z0-9_]*$/.test(scriptName)) {
  err = `[Error] script_name '${scriptName}' must match /^[a-zA-Z_][a-zA-Z0-9_]*$/.`;
} else if (!description) {
  err = "[Error] description is required.";
} else if (description.includes("\n")) {
  err = "[Error] description must be a single line — it becomes the first-line comment.";
}

if (err) {
  console.log(err);
} else {
  const skillRoot = `skills/${slug}`;
  const skillMd = `${skillRoot}/SKILL.md`;
  const scriptPath = `${skillRoot}/scripts/${scriptName}.js`;
  const skillExists = await fs.exists(skillMd);

  if (!skillExists) {
    console.log(`[Error] /${skillMd} not found. Call scaffold first or pick a different slug.`);
  } else if (await fs.exists(scriptPath)) {
    console.log(`[Error] /${scriptPath} already exists. Edit it via fs.writeFile or pick a different script_name.`);
  } else {
    const body = `// ${description}

// TODO: implement. \`args\` is whatever the caller passed via run_snippet.
// Use console.log to return text to the LLM.
console.log("TODO: implement ${scriptName}");
`;
    if (!await fs.exists(`${skillRoot}/scripts`)) {
      await fs.mkdir(`${skillRoot}/scripts`);
    }
    await fs.writeFile(scriptPath, body);
    console.log(
      `Wrote /${scriptPath}. Next:\n` +
      `1. Replace the TODO body via fs.writeFile.\n` +
      `2. validate_skill(slug='${slug}') — verify the package still parses.\n` +
      `3. The script is callable from the LLM as run_snippet skill:<skill name>:${scriptName}.`
    );
  }
}
