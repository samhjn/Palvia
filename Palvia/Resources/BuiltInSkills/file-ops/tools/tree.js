const META = {
  name: "tree",
  description: "Recursive directory listing with depth control. Returns a formatted text tree.",
  parameters: [
    { name: "path",      type: "string", required: false, description: "Root path (default: agent root)" },
    { name: "max_depth", type: "number", required: false, description: "Maximum recursion depth (default: 4)" }
  ]
};

const maxDepth = args.max_depth || 4;
async function walk(path, depth, lines) {
    if (depth > maxDepth) return;
    const raw = await fs.list(path);
    const entries = JSON.parse(raw);
    for (const entry of entries) {
        const rel = path ? path + '/' + entry.name : entry.name;
        const indent = '  '.repeat(depth);
        const tag = entry.is_dir ? '/' : '';
        lines.push(indent + entry.name + tag);
        if (entry.is_dir) await walk(rel, depth + 1, lines);
    }
}
const root = args.path || '';
const lines = [root ? root + '/' : '.'];
await walk(root, 1, lines);
console.log(lines.join('\n'));
