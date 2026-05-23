const META = {
  name: "touch",
  description: "Create an empty file if it doesn't exist (does nothing if the file already exists).",
  parameters: [
    { name: "path", type: "string", required: true, description: "File path to touch" }
  ]
};

const present = await fs.exists(args.path);
if (present) { console.log('OK (already exists)'); }
else {
    const res = await fs.writeFile(args.path, '');
    console.log(res);
}
