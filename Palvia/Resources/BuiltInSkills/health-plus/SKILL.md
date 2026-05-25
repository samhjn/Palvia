---
name: Health Plus
description: "Advanced Apple Health metrics: blood pressure, glucose, oxygen, body temperature, macronutrients, workouts"
palvia:
  version: "1.0"
  tags: [health, fitness, wellness]
---
# Health Plus Skill

Install this skill when you need to read or log Apple Health metrics beyond the
default set (steps, heart rate, sleep, body mass, dietary energy, dietary water).

## Reads
- `skill_health_plus_read_blood_pressure(start_date?, end_date?)` — systolic/diastolic samples (defaults to last 30 days).
- `skill_health_plus_read_blood_glucose(start_date?, end_date?)` — glucose samples (defaults to last 30 days).
- `skill_health_plus_read_blood_oxygen(start_date?, end_date?)` — SpO₂ samples (defaults to last 7 days).
- `skill_health_plus_read_body_temperature(start_date?, end_date?, unit?)` — temperature samples. `unit` is `"c"` (default) or `"f"`.

## Writes — vitals & body composition
- `skill_health_plus_write_blood_pressure(systolic, diastolic, date?)` — mmHg.
- `skill_health_plus_write_blood_glucose(value, unit?, date?)` — `unit` is `"mmol/l"` (default) or `"mg/dl"`.
- `skill_health_plus_write_blood_oxygen(percentage, date?)` — SpO₂ percent (e.g. 98).
- `skill_health_plus_write_body_temperature(value, unit?, date?)` — `unit` is `"c"` (default) or `"f"`.
- `skill_health_plus_write_body_fat(percentage, date?)` — body fat percent (e.g. 22.5).
- `skill_health_plus_write_height(value, unit?, date?)` — `unit` is `"cm"`, `"m"`, `"in"`, or `"ft"`.
- `skill_health_plus_write_heart_rate(bpm, date?)` — manual pulse in beats per minute.

## Writes — dietary macronutrients
- `skill_health_plus_write_dietary_carbohydrates(grams, date?)`
- `skill_health_plus_write_dietary_protein(grams, date?)`
- `skill_health_plus_write_dietary_fat(grams, date?)`

## Writes — workouts
- `skill_health_plus_write_workout(activity_type?, start_date, end_date, energy_kcal?, distance_km?)` — `activity_type` e.g. `"running"`, `"walking"`, `"cycling"`, `"swimming"`, `"yoga"`, `"strength"`.

## Dates & permissions
- All `date`/`start_date`/`end_date` params accept ISO 8601 or `yyyy-MM-dd HH:mm`.
- Writes default `date` to now; read ranges default as noted above.
- These tools route through the `health` permission category: reads require read permission; writes require write permission.

## Bulk or scripted logging
For loops, conditional logic, or combining multiple metrics in one pass, use
`execute_javascript` with the `apple.health.*` namespace directly, e.g.:

    await apple.health.writeBloodPressure({systolic: 120, diastolic: 80});
    let readings = await apple.health.readBloodGlucose({});
