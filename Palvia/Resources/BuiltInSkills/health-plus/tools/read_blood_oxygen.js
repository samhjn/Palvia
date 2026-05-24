const META = {
  name: "read_blood_oxygen",
  description: "Read blood oxygen saturation (SpO₂) samples from Apple Health.",
  parameters: [
    { name: "start_date", type: "string", required: false, description: "Start date. Defaults to 7 days ago." },
    { name: "end_date",   type: "string", required: false, description: "End date. Defaults to now." }
  ]
};

const res = await apple.health.readBloodOxygen(args);
console.log(JSON.stringify(res));
