const META = {
  name: "read_blood_glucose",
  description: "Read blood glucose samples from Apple Health.",
  parameters: [
    { name: "start_date", type: "string", required: false, description: "Start date. Defaults to 30 days ago." },
    { name: "end_date",   type: "string", required: false, description: "End date. Defaults to now." }
  ]
};

const res = await apple.health.readBloodGlucose(args);
console.log(JSON.stringify(res));
