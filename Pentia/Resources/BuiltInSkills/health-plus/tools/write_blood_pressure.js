const META = {
  name: "write_blood_pressure",
  description: "Write a blood pressure reading (systolic/diastolic mmHg) to Apple Health.",
  parameters: [
    { name: "systolic",  type: "number", required: true,  description: "Systolic pressure in mmHg (e.g. 120)" },
    { name: "diastolic", type: "number", required: true,  description: "Diastolic pressure in mmHg (e.g. 80)" },
    { name: "date",      type: "string", required: false, description: "Entry time. Defaults to now." }
  ]
};

const res = await apple.health.writeBloodPressure(args);
console.log(res);
