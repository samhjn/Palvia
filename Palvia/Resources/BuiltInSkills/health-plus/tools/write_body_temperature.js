const META = {
  name: "write_body_temperature",
  description: "Write a body temperature reading to Apple Health.",
  parameters: [
    { name: "value", type: "number", required: true,  description: "Temperature value" },
    { name: "unit",  type: "string", required: false, description: "Temperature unit", enum: ["c", "f"] },
    { name: "date",  type: "string", required: false, description: "Entry time. Defaults to now." }
  ]
};

const res = await apple.health.writeBodyTemperature(args);
console.log(res);
