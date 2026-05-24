const META = {
  name: "write_dietary_fat",
  description: "Write dietary fat (grams) to Apple Health.",
  parameters: [
    { name: "grams", type: "number", required: true,  description: "Fat in grams" },
    { name: "date",  type: "string", required: false, description: "Entry time. Defaults to now." }
  ]
};

const res = await apple.health.writeDietaryFat(args);
console.log(res);
