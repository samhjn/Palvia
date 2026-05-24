---
display_name: ヘルス Plus
description: 進んだ Apple Health メトリクス：血圧、血糖、酸素、体温、マクロ栄養、ワークアウト
---

# ヘルス Plus Skill

既定セット（歩数、心拍、睡眠、体重、食事エネルギー、水分）を超える Apple Health の指標を読み取り／記録する場合にこの Skill をインストールしてください。

## 読み取り
- `skill_health_plus_read_blood_pressure(start_date?, end_date?)` —— 収縮／拡張サンプル（既定は直近 30 日）。
- `skill_health_plus_read_blood_glucose(start_date?, end_date?)` —— 血糖サンプル（既定は直近 30 日）。
- `skill_health_plus_read_blood_oxygen(start_date?, end_date?)` —— SpO₂ サンプル（既定は直近 7 日）。
- `skill_health_plus_read_body_temperature(start_date?, end_date?, unit?)` —— 体温サンプル。`unit` は `"c"`（既定）または `"f"`。

## 書き込み —— バイタルと体組成
- `skill_health_plus_write_blood_pressure(systolic, diastolic, date?)` —— mmHg。
- `skill_health_plus_write_blood_glucose(value, unit?, date?)` —— `unit` は `"mmol/l"`（既定）または `"mg/dl"`。
- `skill_health_plus_write_blood_oxygen(percentage, date?)` —— SpO₂ パーセント（例 98）。
- `skill_health_plus_write_body_temperature(value, unit?, date?)` —— `unit` は `"c"`（既定）または `"f"`。
- `skill_health_plus_write_body_fat(percentage, date?)` —— 体脂肪率（例 22.5）。
- `skill_health_plus_write_height(value, unit?, date?)` —— `unit` は `"cm"`、`"m"`、`"in"`、`"ft"`。
- `skill_health_plus_write_heart_rate(bpm, date?)` —— 手動で 1 分あたりの脈拍。

## 書き込み —— 食事のマクロ栄養
- `skill_health_plus_write_dietary_carbohydrates(grams, date?)`
- `skill_health_plus_write_dietary_protein(grams, date?)`
- `skill_health_plus_write_dietary_fat(grams, date?)`

## 書き込み —— ワークアウト
- `skill_health_plus_write_workout(activity_type?, start_date, end_date, energy_kcal?, distance_km?)` —— `activity_type` 例 `"running"`、`"walking"`、`"cycling"`、`"swimming"`、`"yoga"`、`"strength"`。

## 日付と権限
- すべての `date`/`start_date`/`end_date` パラメータは ISO 8601 または `yyyy-MM-dd HH:mm` を受け付けます。
- 書き込みの `date` の既定値は現在時刻。読み取り範囲の既定値は上記の通り。
- これらのツールは `health` 権限カテゴリを経由し、読み取りは読取権限、書き込みは書込権限が必要です。

## 一括記録・スクリプト化
ループや条件分岐、複数指標の一括処理が必要な場合は `execute_javascript` で `apple.health.*` ネームスペースを直接使用します：

    await apple.health.writeBloodPressure({systolic: 120, diastolic: 80});
    let readings = await apple.health.readBloodGlucose({});
