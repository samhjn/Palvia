---
display_name: 技能建構器
description: 透過 fs.* 橋接直接撰寫和編輯 Pentia 技能。包含腳手架、工具/腳本產生器、驗證以及範例參考。
---
# 技能建構器（Skill Builder）

當使用者要求你建立、修改或分支一個 Pentia 技能時使用本技能。Pentia 的技能
是位於 `/skills/<slug>/` 下的資料夾，透過 `fs.*` 橋接來撰寫——並沒有
`create_skill`/`edit_skill` 這類 LLM 工具。規範結構見
`references/example-tooled.md`。

## 撰寫流程（標準路徑）

1. **選定 slug。** 全小寫、以連字號拼接、不與既有衝突。先用
   `fs.list('skills')` 與 `list_skills` 檢查現有 slug。Slug 是穩定識別
   ——重新命名 slug 會讓已安裝它的 agent 失效。
2. **產生骨架。** 呼叫
   `skill_skill_builder_scaffold(slug, name, description, tags?)`，一次
   寫出最小可用的 `SKILL.md` 以及空的 `tools/` 與 `scripts/` 資料夾。
3. **新增工具（function-call 工具）。** 對每個工具呼叫
   `skill_skill_builder_add_tool(slug, tool_name, description, parameters?)`。
   它會寫出 `tools/<tool_name>.js`，META 依據輸入填好，函式主體留作
   `TODO`。用 `fs.writeFile` 把 body 換成你的實作。
4. **新增腳本（可選，供 `run_snippet` 呼叫）。** 對每個腳本呼叫
   `skill_skill_builder_add_script(slug, script_name, description)`，
   寫法相同：產生骨架後用 `fs.writeFile` 換掉 body。
5. **驗證。** `validate_skill(slug=...)` 執行的就是自動重新載入路徑所用的
   Swift 端 parser。安裝前必須先解掉所有 error；warning 僅作為提示。
6. **安裝。** `install_skill(name=<frontmatter 的 name>)`。Pentia 會從
   磁碟上的套件具體化出一筆 `Skill` 紀錄並綁定到目前 agent。自訂工具
   會立即作為 `skill_<slug>_<tool>` 可被呼叫。

## 編輯既有技能

1. **先讀。** `fs.readFile('skills/<slug>/SKILL.md')`，避免誤覆寫無關內容。
2. **寫入。** `fs.writeFile('skills/<slug>/...')`。寫入成功後會自動
   觸發 reload；若改壞了無法解析，技能會保留上一份可用的版本繼續運作，
   直到你修好為止。
3. **再次驗證。** 每批修改後都 `validate_skill(slug=...)` 一次。
4. **不需重裝。** 快取的 Skill 紀錄會自動更新。只有改 slug 才需要
   先解除安裝再重新安裝。

## 分支內建技能

內建技能（slug 在 `BuiltInSkills.shippedSlugs` 中的那些）是唯讀的。
修改前先分支：

    fs.cp('skills/deep-research', 'skills/my-research', { recursive: true });

副本會落在 `<Documents>/Skills/` 之下，完全可寫。接著照常編輯、
驗證、`install_skill` 即可。

## 權限說明

寫入 `/skills/<slug>/` 需要 `fs_skill_write` 這個 per-agent 權限，並在
動作本身的權限（例如 `files.writeFile`）之上再疊一層。沒有
`fs_skill_write` 的 agent 仍可讀取技能套件並使用已安裝的技能——只是
不能撰寫或修改。

## 延伸閱讀

- `references/example-simple.md` —— 僅含說明文件、未帶工具/腳本的最小技能範例。
- `references/example-tooled.md` —— 含一個工具與一個腳本的完整技能範例。
