---
display_name: 健康 Plus
description: "进阶 Apple Health 指标:血压、血糖、血氧、体温、宏量营养、锻炼"
---

# 健康 Plus Skill

当你需要读取或记录默认集合（步数、心率、睡眠、体重、膳食能量、饮水）之外的 Apple Health 指标时，安装此 Skill。

## 读取
- `skill_health_plus_read_blood_pressure(start_date?, end_date?)` —— 收缩/舒张压样本（默认近 30 天）。
- `skill_health_plus_read_blood_glucose(start_date?, end_date?)` —— 血糖样本（默认近 30 天）。
- `skill_health_plus_read_blood_oxygen(start_date?, end_date?)` —— SpO₂ 样本（默认近 7 天）。
- `skill_health_plus_read_body_temperature(start_date?, end_date?, unit?)` —— 体温样本。`unit` 为 `"c"`（默认）或 `"f"`。

## 写入 —— 生命体征与身体成分
- `skill_health_plus_write_blood_pressure(systolic, diastolic, date?)` —— 单位 mmHg。
- `skill_health_plus_write_blood_glucose(value, unit?, date?)` —— `unit` 为 `"mmol/l"`（默认）或 `"mg/dl"`。
- `skill_health_plus_write_blood_oxygen(percentage, date?)` —— SpO₂ 百分比（如 98）。
- `skill_health_plus_write_body_temperature(value, unit?, date?)` —— `unit` 为 `"c"`（默认）或 `"f"`。
- `skill_health_plus_write_body_fat(percentage, date?)` —— 体脂百分比（如 22.5）。
- `skill_health_plus_write_height(value, unit?, date?)` —— `unit` 为 `"cm"`、`"m"`、`"in"` 或 `"ft"`。
- `skill_health_plus_write_heart_rate(bpm, date?)` —— 手动记录心率（每分钟）。

## 写入 —— 膳食宏量营养
- `skill_health_plus_write_dietary_carbohydrates(grams, date?)`
- `skill_health_plus_write_dietary_protein(grams, date?)`
- `skill_health_plus_write_dietary_fat(grams, date?)`

## 写入 —— 锻炼
- `skill_health_plus_write_workout(activity_type?, start_date, end_date, energy_kcal?, distance_km?)` —— `activity_type` 例如 `"running"`、`"walking"`、`"cycling"`、`"swimming"`、`"yoga"`、`"strength"`。

## 日期与权限
- 所有 `date`/`start_date`/`end_date` 参数接受 ISO 8601 或 `yyyy-MM-dd HH:mm`。
- 写入默认 `date` 为当前；读取范围默认值如上。
- 这些工具走 `health` 权限分类：读需读权限，写需写权限。

## 批量或脚本化记录
需要循环、条件逻辑或一次合并多个指标时，在 `execute_javascript` 中直接使用 `apple.health.*` 命名空间，例如：

    await apple.health.writeBloodPressure({systolic: 120, diastolic: 80});
    let readings = await apple.health.readBloodGlucose({});
