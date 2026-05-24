const META = {
  name: "exists",
  description: "Check whether a file or directory exists. Returns 'true' or 'false'.",
  parameters: [
    { name: "path", type: "string", required: true, description: "Path to check" }
  ]
};

const present = await fs.exists(args.path);
console.log(present ? 'true' : 'false');
