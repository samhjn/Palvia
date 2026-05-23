const META = {
  name: "write_body_fat",
  description: "Write body fat percentage to Apple Health.",
  parameters: [
    { name: "percentage", type: "number", required: true,  description: "Body fat percentage (e.g. 22.5)" },
    { name: "date",       type: "string", required: false, description: "Entry time. Defaults to now." }
  ]
};

const res = await apple.health.writeBodyFat(args);
console.log(res);
