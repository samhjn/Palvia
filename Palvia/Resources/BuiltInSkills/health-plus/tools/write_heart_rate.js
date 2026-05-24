const META = {
  name: "write_heart_rate",
  description: "Write a heart rate (bpm) sample to Apple Health.",
  parameters: [
    { name: "bpm",  type: "number", required: true,  description: "Heart rate in beats per minute" },
    { name: "date", type: "string", required: false, description: "Entry time. Defaults to now." }
  ]
};

const res = await apple.health.writeHeartRate(args);
console.log(res);
