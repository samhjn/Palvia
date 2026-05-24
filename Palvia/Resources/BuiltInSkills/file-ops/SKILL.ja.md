---
display_name: ファイル操作
description: 高度なファイル操作：コピー、移動、ディレクトリ管理、リッチな stat
---

# ファイル操作 Skill

ディレクトリ管理、一括コピー、移動／名前変更、既定の `file_*` ツールでは足りないリッチなメタデータが必要な場合にこの Skill をインストールしてください。

## ツールの使い分け
- **ディレクトリ作成**：`skill_file_ops_mkdir(path)` —— 中間階層も作成。
- **コピー**：`skill_file_ops_cp(src, dest, recursive?)` —— `recursive` は既定 true。
- **移動 / 名前変更**：`skill_file_ops_mv(src, dest)`。
- **リッチなメタデータ**：`skill_file_ops_stat(path)` —— JSON `{name,path,size,is_file,is_dir,is_image,mtime_ms,ctime_ms}` を返す。
- **ディレクトリツリー**：`skill_file_ops_tree(path?, max_depth?)` —— 再帰的に列挙。
- **存在確認**：`skill_file_ops_exists(path)` —— `"true"` または `"false"` を返す。
- **Touch**：`skill_file_ops_touch(path)` —— 無ければ空ファイルを作成。

## POSIX ファイルディスクリプタ操作
細かな I/O（seek、部分読み書き、truncate）が必要な場合は `execute_javascript` で `fs` ネームスペースを直接使用：

    let fd = await fs.open("log.txt", "a+");
    await fs.write(fd, "new line\n");
    await fs.seek(fd, 0, "start");
    let head = await fs.read(fd, 100);
    await fs.close(fd);

オープンフラグ：`"r"`、`"r+"`、`"w"`、`"w+"`、`"a"`、`"a+"`（Node 互換）。
seek の whence：`"start"` | `"current"` | `"end"`（または `0` | `1` | `2`）。

ファイルディスクリプタは単一の `execute_javascript` 呼び出し内で有効で、呼び出し終了時に自動で閉じられますが、明示的な close を推奨します。
