const META = {
  name: "write_dietary_carbohydrates",
  description: "Write dietary carbohydrates (grams) to Apple Health.",
  parameters: [
    { name: "grams", type: "number", required: true,  description: "Carbohydrates in grams" },
    { name: "date",  type: "string", required: false, description: "Entry time. Defaults to now." }
  ]
};

const res = await apple.health.writeDietaryCarbohydrates(args);
console.log(res);
