const META = {
  name: "write_blood_oxygen",
  description: "Write a blood oxygen saturation (SpO₂ %) reading to Apple Health.",
  parameters: [
    { name: "percentage", type: "number", required: true,  description: "SpO₂ percentage (e.g. 98)" },
    { name: "date",       type: "string", required: false, description: "Entry time. Defaults to now." }
  ]
};

const res = await apple.health.writeBloodOxygen(args);
console.log(res);
