---
display_name: 檔案操作
description: 進階檔案操作：複製、移動、目錄管理、豐富中繼資料
---

# 檔案操作 Skill

當你需要目錄管理、批次複製、移動/重新命名，或比預設 `file_*` 工具更豐富的中繼資料時，安裝此 Skill。

## 工具使用指引
- **建立目錄**：`skill_file_ops_mkdir(path)` —— 自動建立中間父目錄。
- **複製**：`skill_file_ops_cp(src, dest, recursive?)` —— `recursive` 預設為 true。
- **移動 / 重新命名**：`skill_file_ops_mv(src, dest)`。
- **豐富中繼資料**：`skill_file_ops_stat(path)` —— 回傳 JSON `{name,path,size,is_file,is_dir,is_image,mtime_ms,ctime_ms}`。
- **目錄樹**：`skill_file_ops_tree(path?, max_depth?)` —— 遞迴列出。
- **檢查存在**：`skill_file_ops_exists(path)` —— 回傳 `"true"` 或 `"false"`。
- **Touch**：`skill_file_ops_touch(path)` —— 缺失時建立空檔案。

## POSIX 檔案描述子操作
需要細緻 I/O（seek、部分讀寫、truncate）時，在 `execute_javascript` 中直接使用 `fs` 命名空間：

    let fd = await fs.open("log.txt", "a+");
    await fs.write(fd, "new line\n");
    await fs.seek(fd, 0, "start");
    let head = await fs.read(fd, 100);
    await fs.close(fd);

開啟旗標：`"r"`、`"r+"`、`"w"`、`"w+"`、`"a"`、`"a+"`（相容 Node）。
seek 的 whence：`"start"` | `"current"` | `"end"`（或 `0` | `1` | `2`）。

檔案描述子僅在單次 `execute_javascript` 呼叫期間有效，結束時自動關閉 —— 但顯式關閉是良好習慣。
