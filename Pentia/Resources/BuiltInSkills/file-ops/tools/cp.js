const META = {
  name: "cp",
  description: "Copy a file or directory. Recursive by default for directories.",
  parameters: [
    { name: "src",       type: "string",  required: true,  description: "Source path" },
    { name: "dest",      type: "string",  required: true,  description: "Destination path" },
    { name: "recursive", type: "boolean", required: false, description: "Copy directories recursively (default: true)" }
  ]
};

const recursive = args.recursive !== false;
const res = await fs.cp(args.src, args.dest, {recursive: recursive});
console.log(res);
