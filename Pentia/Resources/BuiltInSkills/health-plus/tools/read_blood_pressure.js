const META = {
  name: "read_blood_pressure",
  description: "Read blood pressure (systolic/diastolic) samples from Apple Health.",
  parameters: [
    { name: "start_date", type: "string", required: false, description: "Start date (ISO 8601 or yyyy-MM-dd HH:mm). Defaults to 30 days ago." },
    { name: "end_date",   type: "string", required: false, description: "End date. Defaults to now." }
  ]
};

const res = await apple.health.readBloodPressure(args);
console.log(JSON.stringify(res));
