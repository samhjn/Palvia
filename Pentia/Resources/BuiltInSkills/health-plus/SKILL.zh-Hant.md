---
display_name: 健康 Plus
description: 進階 Apple Health 指標：血壓、血糖、血氧、體溫、巨量營養、運動
---

# 健康 Plus Skill

當你需要讀取或記錄預設集合（步數、心率、睡眠、體重、膳食能量、飲水）之外的 Apple Health 指標時，安裝此 Skill。

## 讀取
- `skill_health_plus_read_blood_pressure(start_date?, end_date?)` —— 收縮/舒張壓樣本（預設近 30 天）。
- `skill_health_plus_read_blood_glucose(start_date?, end_date?)` —— 血糖樣本（預設近 30 天）。
- `skill_health_plus_read_blood_oxygen(start_date?, end_date?)` —— SpO₂ 樣本（預設近 7 天）。
- `skill_health_plus_read_body_temperature(start_date?, end_date?, unit?)` —— 體溫樣本。`unit` 為 `"c"`（預設）或 `"f"`。

## 寫入 —— 生命徵象與身體組成
- `skill_health_plus_write_blood_pressure(systolic, diastolic, date?)` —— 單位 mmHg。
- `skill_health_plus_write_blood_glucose(value, unit?, date?)` —— `unit` 為 `"mmol/l"`（預設）或 `"mg/dl"`。
- `skill_health_plus_write_blood_oxygen(percentage, date?)` —— SpO₂ 百分比（例如 98）。
- `skill_health_plus_write_body_temperature(value, unit?, date?)` —— `unit` 為 `"c"`（預設）或 `"f"`。
- `skill_health_plus_write_body_fat(percentage, date?)` —— 體脂百分比（例如 22.5）。
- `skill_health_plus_write_height(value, unit?, date?)` —— `unit` 為 `"cm"`、`"m"`、`"in"` 或 `"ft"`。
- `skill_health_plus_write_heart_rate(bpm, date?)` —— 手動記錄心率（每分鐘）。

## 寫入 —— 膳食巨量營養
- `skill_health_plus_write_dietary_carbohydrates(grams, date?)`
- `skill_health_plus_write_dietary_protein(grams, date?)`
- `skill_health_plus_write_dietary_fat(grams, date?)`

## 寫入 —— 運動
- `skill_health_plus_write_workout(activity_type?, start_date, end_date, energy_kcal?, distance_km?)` —— `activity_type` 例如 `"running"`、`"walking"`、`"cycling"`、`"swimming"`、`"yoga"`、`"strength"`。

## 日期與權限
- 所有 `date`/`start_date`/`end_date` 參數接受 ISO 8601 或 `yyyy-MM-dd HH:mm`。
- 寫入預設 `date` 為目前；讀取範圍預設值如上。
- 這些工具走 `health` 權限分類：讀取需讀權限；寫入需寫權限。

## 批次或指令稿記錄
需要迴圈、條件邏輯或一次合併多個指標時，在 `execute_javascript` 中直接使用 `apple.health.*` 命名空間，例如：

    await apple.health.writeBloodPressure({systolic: 120, diastolic: 80});
    let readings = await apple.health.readBloodGlucose({});
