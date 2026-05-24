const META = {
  name: "mkdir",
  description: "Create a directory (including intermediate components). Idempotent.",
  parameters: [
    { name: "path", type: "string", required: true, description: "Directory path to create" }
  ]
};

const res = await fs.mkdir(args.path);
console.log(res);
