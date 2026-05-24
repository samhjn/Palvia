const META = {
  name: "write_workout",
  description: "Write a workout session to Apple Health.",
  parameters: [
    { name: "activity_type", type: "string", required: false, description: "Activity type, e.g. running, walking, cycling, swimming, yoga, strength" },
    { name: "start_date",    type: "string", required: true,  description: "Workout start time (ISO 8601 or yyyy-MM-dd HH:mm)" },
    { name: "end_date",      type: "string", required: true,  description: "Workout end time (ISO 8601 or yyyy-MM-dd HH:mm)" },
    { name: "energy_kcal",   type: "number", required: false, description: "Active energy burned in kcal" },
    { name: "distance_km",   type: "number", required: false, description: "Distance in kilometers" }
  ]
};

const res = await apple.health.writeWorkout(args);
console.log(res);
