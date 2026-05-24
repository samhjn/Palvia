---
display_name: スキルビルダー
description: fs.* ブリッジ経由で Palvia スキルを直接作成・編集します。スキャフォールディング、ツール／スクリプトのジェネレータ、検証、リファレンス例を含みます。
---
# スキルビルダー（Skill Builder）

ユーザーから Palvia スキルの作成・修正・フォークを依頼されたときに使用してください。
Palvia のスキルは `/skills/<slug>/` 配下のディレクトリで、`fs.*` ブリッジを使って
記述します — `create_skill` / `edit_skill` のような LLM ツールはありません。
標準構造は `references/example-tooled.md` に記載しています。

## 作成フロー（標準パス）

1. **slug を決める。** 小文字・ハイフン区切り・既存と衝突しないものを選ぶ。
   既存の slug は `fs.list('skills')` と `list_skills` で確認。slug は安定識別子
   なので、リネームするとインストール済みエージェントが壊れます。
2. **スキャフォールド。** `skill_skill_builder_scaffold(slug, name, description, tags?)`
   を呼び出す。最小限の `SKILL.md` と空の `tools/` ・ `scripts/` ディレクトリを
   一度に生成します。
3. **ツールを追加（function-call ツール）。** ツールごとに
   `skill_skill_builder_add_tool(slug, tool_name, description, parameters?)`
   を呼ぶ。`tools/<tool_name>.js` に META 宣言を入力どおり埋めた状態で書き出し、
   本体は `TODO` のままになります。`fs.writeFile` で本体を実装に置き換えてください。
4. **スクリプトを追加（任意・`run_snippet` から呼ばれるヘルパー）。**
   `skill_skill_builder_add_script(slug, script_name, description)` を呼ぶ。
   同じく雛形が出るので `fs.writeFile` で本体を差し替えます。
5. **検証。** `validate_skill(slug=...)` は自動リロードで使われるのと同じ
   Swift 側 parser を実行します。インストール前に error は必ず潰しておくこと。
   warning は参考情報です。
6. **インストール。** `install_skill(name=<frontmatter の name>)`。Palvia は
   ディスクのパッケージから `Skill` 行を具体化して現在のエージェントに紐づけ、
   カスタムツールは直ちに `skill_<slug>_<tool>` として呼び出せるようになります。

## 既存スキルの編集

1. **先に読む。** `fs.readFile('skills/<slug>/SKILL.md')` で関係ない部分を
   破壊的に書き換えないようにしてください。
2. **書き込む。** `fs.writeFile('skills/<slug>/...')`。書き込み成功後に
   自動リロードが走り、解析失敗時はパッケージを直すまで「最後に使えた」
   バージョンで動き続けます。
3. **再検証。** 編集をひとまとまり済ませるたびに `validate_skill(slug=...)` を実行。
4. **再インストール不要。** キャッシュの Skill 行は自動更新されます。
   slug の変更だけはアンインストール → 再インストールが必要です。

## ビルトインスキルをフォークする

ビルトインスキル（`BuiltInSkills.shippedSlugs` に含まれる slug）は読み取り専用です。
編集する前にフォークしてください:

    fs.cp('skills/deep-research', 'skills/my-research', { recursive: true });

コピーは `<Documents>/Skills/` 配下に作られ、完全に書き込み可能になります。
あとは通常どおり編集・検証・`install_skill` で済みます。

## 権限について

`/skills/<slug>/` への書き込みには、アクション自体の権限（例:
`files.writeFile`）に加えて、エージェント単位の `fs_skill_write` 権限が必要です。
`fs_skill_write` がないエージェントもパッケージの読み取りやインストール済み
スキルの利用は可能で、作成・編集だけが拒否されます。

## 関連

- `references/example-simple.md` — 散文だけでツールもスクリプトも持たない最小スキルの例。
- `references/example-tooled.md` — ツール 1 個とスクリプト 1 個を持つスキルの完全な例。
