const META = {
  name: "write_blood_glucose",
  description: "Write a blood glucose reading to Apple Health.",
  parameters: [
    { name: "value", type: "number", required: true,  description: "Blood glucose value" },
    { name: "unit",  type: "string", required: false, description: "Unit for value", enum: ["mmol/l", "mg/dl"] },
    { name: "date",  type: "string", required: false, description: "Entry time. Defaults to now." }
  ]
};

const res = await apple.health.writeBloodGlucose(args);
console.log(res);
