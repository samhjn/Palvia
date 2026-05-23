const META = {
  name: "write_dietary_protein",
  description: "Write dietary protein (grams) to Apple Health.",
  parameters: [
    { name: "grams", type: "number", required: true,  description: "Protein in grams" },
    { name: "date",  type: "string", required: false, description: "Entry time. Defaults to now." }
  ]
};

const res = await apple.health.writeDietaryProtein(args);
console.log(res);
