const META = {
  name: "add_tool",
  description: "Add a function-call tool to an existing skill package. Generates a tools/<tool_name>.js with the META declaration prefilled from your inputs and a TODO body. After running this, replace the TODO via fs.writeFile and call validate_skill(slug=...) to verify.",
  parameters: [
    { name: "slug",        type: "string", required: true,  description: "Slug of the target skill package under /skills/." },
    { name: "tool_name",   type: "string", required: true,  description: "Tool name (must match /[a-zA-Z_][a-zA-Z0-9_]*/). Becomes part of the LLM tool name skill_<slug>_<tool_name>." },
    { name: "description", type: "string", required: true,  description: "≤200-char one-line description used by the model to pick the tool." },
    { name: "parameters",  type: "string", required: false, description: "JSON array of {name,type,required?,description?,enum?} entries. Defaults to []." }
  ]
};

const slug = (args.slug || "").trim();
const toolName = (args.tool_name || "").trim();
const description = (args.description || "").trim();
const validTypes = ["string", "number", "boolean", "array", "object"];

let err = null;
let params = [];

if (!slug) {
  err = "[Error] slug is required.";
} else if (!/^[a-z0-9]+(-[a-z0-9]+)*$/.test(slug)) {
  err = `[Error] slug '${slug}' must match /^[a-z0-9]+(-[a-z0-9]+)*$/ (lowercase, hyphenated alphanumerics).`;
} else if (!toolName) {
  err = "[Error] tool_name is required.";
} else if (!/^[a-zA-Z_][a-zA-Z0-9_]*$/.test(toolName)) {
  err = `[Error] tool_name '${toolName}' must match /^[a-zA-Z_][a-zA-Z0-9_]*$/.`;
} else if (!description) {
  err = "[Error] description is required.";
} else if (description.length > 200) {
  err = `[Error] description is ${description.length} characters; the validator's max is 200.`;
} else if (args.parameters) {
  try {
    params = JSON.parse(args.parameters);
    if (!Array.isArray(params)) {
      err = "[Error] parameters must be a JSON array.";
    } else {
      for (let i = 0; i < params.length; i++) {
        const p = params[i];
        if (!p || typeof p !== "object") { err = `[Error] parameters[${i}] is not an object.`; break; }
        if (typeof p.name !== "string" || !p.name) { err = `[Error] parameters[${i}].name is required.`; break; }
        if (typeof p.type !== "string" || !validTypes.includes(p.type)) {
          err = `[Error] parameters[${i}].type must be one of: ${validTypes.join(", ")}.`;
          break;
        }
      }
    }
  } catch (e) {
    err = `[Error] parameters JSON parse failed: ${e.message}`;
  }
}

if (err) {
  console.log(err);
} else {
  const skillRoot = `skills/${slug}`;
  const skillMd = `${skillRoot}/SKILL.md`;
  const toolPath = `${skillRoot}/tools/${toolName}.js`;
  const skillExists = await fs.exists(skillMd);

  if (!skillExists) {
    console.log(`[Error] /${skillMd} not found. Call scaffold first or pick a different slug.`);
  } else if (await fs.exists(toolPath)) {
    console.log(`[Error] /${toolPath} already exists. Edit it via fs.writeFile or pick a different tool_name.`);
  } else {
    // Render the parameters array. JSON.stringify keeps the values valid;
    // we just sprinkle commas + indentation for readability.
    const paramLines = params.map(p => {
      const fields = [
        `name: ${JSON.stringify(p.name)}`,
        `type: ${JSON.stringify(p.type)}`,
      ];
      fields.push(`required: ${p.required === false ? "false" : "true"}`);
      if (typeof p.description === "string" && p.description) {
        fields.push(`description: ${JSON.stringify(p.description)}`);
      }
      if (Array.isArray(p.enum)) {
        fields.push(`enum: ${JSON.stringify(p.enum)}`);
      }
      return `    { ${fields.join(", ")} }`;
    });
    const paramBlock = paramLines.length === 0 ? "[]" : `[\n${paramLines.join(",\n")}\n  ]`;

    const body = `const META = {
  name: ${JSON.stringify(toolName)},
  description: ${JSON.stringify(description)},
  parameters: ${paramBlock}
};

// TODO: implement. \`args\` carries the typed parameters. Use console.log
// to return text to the LLM; throwing will surface as a tool error.
console.log("TODO: implement ${toolName}");
`;

    if (!await fs.exists(`${skillRoot}/tools`)) {
      await fs.mkdir(`${skillRoot}/tools`);
    }
    await fs.writeFile(toolPath, body);
    console.log(
      `Wrote /${toolPath}. Next:\n` +
      `1. Replace the TODO body via fs.writeFile.\n` +
      `2. validate_skill(slug='${slug}') — verify the package still parses.\n` +
      `3. install_skill (if not yet installed) so the new tool surfaces as skill_${slug.replace(/-/g, "_")}_${toolName}.`
    );
  }
}
