const META = {
  name: "read_body_temperature",
  description: "Read body temperature samples from Apple Health.",
  parameters: [
    { name: "start_date", type: "string", required: false, description: "Start date. Defaults to 30 days ago." },
    { name: "end_date",   type: "string", required: false, description: "End date. Defaults to now." },
    { name: "unit",       type: "string", required: false, description: "Temperature unit", enum: ["c", "f"] }
  ]
};

const res = await apple.health.readBodyTemperature(args);
console.log(JSON.stringify(res));
