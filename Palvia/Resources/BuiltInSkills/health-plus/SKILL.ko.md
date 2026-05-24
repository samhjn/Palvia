---
display_name: 건강 Plus
description: "고급 Apple Health 지표: 혈압, 혈당, 산소, 체온, 다량영양소, 운동"
---

# 건강 Plus Skill

기본 집합(걸음 수, 심박수, 수면, 체중, 섭취 에너지, 수분) 외의 Apple Health 지표를 읽거나 기록해야 할 때 이 Skill 을 설치하세요.

## 읽기
- `skill_health_plus_read_blood_pressure(start_date?, end_date?)` —— 수축기/이완기 샘플 (기본 최근 30 일).
- `skill_health_plus_read_blood_glucose(start_date?, end_date?)` —— 혈당 샘플 (기본 최근 30 일).
- `skill_health_plus_read_blood_oxygen(start_date?, end_date?)` —— SpO₂ 샘플 (기본 최근 7 일).
- `skill_health_plus_read_body_temperature(start_date?, end_date?, unit?)` —— 체온 샘플. `unit` 은 `"c"` (기본) 또는 `"f"`.

## 쓰기 —— 생체 징후와 체성분
- `skill_health_plus_write_blood_pressure(systolic, diastolic, date?)` —— mmHg.
- `skill_health_plus_write_blood_glucose(value, unit?, date?)` —— `unit` 은 `"mmol/l"` (기본) 또는 `"mg/dl"`.
- `skill_health_plus_write_blood_oxygen(percentage, date?)` —— SpO₂ 퍼센트 (예: 98).
- `skill_health_plus_write_body_temperature(value, unit?, date?)` —— `unit` 은 `"c"` (기본) 또는 `"f"`.
- `skill_health_plus_write_body_fat(percentage, date?)` —— 체지방률 (예: 22.5).
- `skill_health_plus_write_height(value, unit?, date?)` —— `unit` 은 `"cm"`, `"m"`, `"in"`, `"ft"`.
- `skill_health_plus_write_heart_rate(bpm, date?)` —— 수동 심박수 (분당).

## 쓰기 —— 식이 다량영양소
- `skill_health_plus_write_dietary_carbohydrates(grams, date?)`
- `skill_health_plus_write_dietary_protein(grams, date?)`
- `skill_health_plus_write_dietary_fat(grams, date?)`

## 쓰기 —— 운동
- `skill_health_plus_write_workout(activity_type?, start_date, end_date, energy_kcal?, distance_km?)` —— `activity_type` 예: `"running"`, `"walking"`, `"cycling"`, `"swimming"`, `"yoga"`, `"strength"`.

## 날짜 및 권한
- 모든 `date`/`start_date`/`end_date` 파라미터는 ISO 8601 또는 `yyyy-MM-dd HH:mm` 을 받습니다.
- 쓰기의 `date` 기본값은 현재 시각; 읽기 범위 기본값은 위와 같습니다.
- 이 도구들은 `health` 권한 범주를 통해 라우팅됩니다: 읽기는 읽기 권한, 쓰기는 쓰기 권한이 필요합니다.

## 일괄 또는 스크립트 기록
반복, 조건 로직, 또는 여러 지표를 한 번에 결합해야 할 때는 `execute_javascript` 에서 `apple.health.*` 네임스페이스를 직접 사용하세요:

    await apple.health.writeBloodPressure({systolic: 120, diastolic: 80});
    let readings = await apple.health.readBloodGlucose({});
