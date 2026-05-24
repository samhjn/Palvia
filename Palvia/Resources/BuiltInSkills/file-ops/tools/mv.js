const META = {
  name: "mv",
  description: "Move or rename a file or directory.",
  parameters: [
    { name: "src",  type: "string", required: true, description: "Source path" },
    { name: "dest", type: "string", required: true, description: "Destination path" }
  ]
};

const res = await fs.mv(args.src, args.dest);
console.log(res);
