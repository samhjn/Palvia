---
display_name: 技能构建器
description: 通过 fs.* 桥接直接创作和编辑 Palvia 技能。包含脚手架、工具/脚本生成器、校验以及示例参考。
---
# 技能构建器（Skill Builder）

当用户要求你创建、修改或复刻一个 Palvia 技能时使用本技能。Palvia 的技能
是位于 `/skills/<slug>/` 下的目录，通过 `fs.*` 桥接来撰写——没有
`create_skill`/`edit_skill` 之类的 LLM 工具。规范结构见
`references/example-tooled.md`。

## 创作流程（标准路径）

1. **选定 slug。** 全小写、用连字符拼接、不与已有冲突。先用
   `fs.list('skills')` 与 `list_skills` 检查现有 slug。Slug 是稳定标识
   ——重命名 slug 会导致已安装它的 agent 失效。
2. **生成骨架。** 调用
   `skill_skill_builder_scaffold(slug, name, description, tags?)`，一次
   写出最小可用的 `SKILL.md` 以及空的 `tools/` 与 `scripts/` 目录。
3. **添加工具（function-call 工具）。** 对每个工具调用
   `skill_skill_builder_add_tool(slug, tool_name, description, parameters?)`。
   它会写出 `tools/<tool_name>.js`，META 已根据输入填好，函数体留作
   `TODO`。用 `fs.writeFile` 把 body 替换成你的实现。
4. **添加脚本（可选，供 `run_snippet` 调用）。** 对每个脚本调用
   `skill_skill_builder_add_script(slug, script_name, description)`，
   写法相同：生成骨架后用 `fs.writeFile` 替换 body。
5. **校验。** `validate_skill(slug=...)` 运行的就是自动重载路径所用的
   Swift 端 parser。安装前必须把所有 error 修掉；warning 仅作提示。
6. **安装。** `install_skill(name=<frontmatter 中的 name>)`。Palvia 会
   从磁盘上的包物化出一条 `Skill` 记录并绑定到当前 agent。自定义工具
   立即作为 `skill_<slug>_<tool>` 可被调用。

## 修改既有技能

1. **先读。** `fs.readFile('skills/<slug>/SKILL.md')`，避免误覆盖无关内容。
2. **写入。** `fs.writeFile('skills/<slug>/...')`。写入成功后会自动
   触发 reload；若改坏了无法解析，技能会保留上一份可用的版本继续工作，
   直到你修好。
3. **再次校验。** 每批修改后都 `validate_skill(slug=...)` 一次。
4. **无需重装。** 缓存的 Skill 记录会自动更新。只有改 slug 才需要
   先卸载再安装。

## 复刻内置技能

内置技能（slug 在 `BuiltInSkills.shippedSlugs` 中的那些）是只读的。
修改前先复刻：

    fs.cp('skills/deep-research', 'skills/my-research', { recursive: true });

复制出来的副本落到 `<Documents>/Skills/` 下，完全可写。然后照常编辑、
校验、`install_skill` 即可。

## 权限说明

向 `/skills/<slug>/` 写入需要 `fs_skill_write` 这一 per-agent 权限，并
在动作本身的权限（如 `files.writeFile`）之上再叠一层。没有
`fs_skill_write` 的 agent 仍可读取技能包并使用已安装的技能——只是不能
创作或修改。

## 另见

- `references/example-simple.md` —— 仅含说明文档、不带工具/脚本的最小技能示例。
- `references/example-tooled.md` —— 包含一个工具与一个脚本的完整技能示例。
