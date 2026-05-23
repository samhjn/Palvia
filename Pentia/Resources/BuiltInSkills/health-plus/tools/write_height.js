const META = {
  name: "write_height",
  description: "Write height to Apple Health.",
  parameters: [
    { name: "value", type: "number", required: true,  description: "Height value" },
    { name: "unit",  type: "string", required: false, description: "Unit for value", enum: ["cm", "m", "in", "ft"] },
    { name: "date",  type: "string", required: false, description: "Entry time. Defaults to now." }
  ]
};

const res = await apple.health.writeHeight(args);
console.log(res);
