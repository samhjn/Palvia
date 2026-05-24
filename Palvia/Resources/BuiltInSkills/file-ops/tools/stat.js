const META = {
  name: "stat",
  description: "Return JSON metadata for a file or directory (size, mtime_ms, ctime_ms, is_file, is_dir).",
  parameters: [
    { name: "path", type: "string", required: true, description: "Path to inspect" }
  ]
};

const res = await fs.stat(args.path);
console.log(res);
