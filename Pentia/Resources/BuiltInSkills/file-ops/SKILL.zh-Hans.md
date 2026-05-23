---
display_name: 文件操作
description: 高级文件操作：复制、移动、目录管理、富元数据
---

# 文件操作 Skill

当你需要目录管理、批量复制、移动/重命名，或比默认 `file_*` 工具更丰富的元数据时，安装此 Skill。

## 工具使用指南
- **创建目录**：`skill_file_ops_mkdir(path)` —— 自动创建中间父目录。
- **复制**：`skill_file_ops_cp(src, dest, recursive?)` —— `recursive` 默认 true。
- **移动 / 重命名**：`skill_file_ops_mv(src, dest)`。
- **富元数据**：`skill_file_ops_stat(path)` —— 返回 JSON `{name,path,size,is_file,is_dir,is_image,mtime_ms,ctime_ms}`。
- **目录树**：`skill_file_ops_tree(path?, max_depth?)` —— 递归列举。
- **检查存在**：`skill_file_ops_exists(path)` —— 返回 `"true"` 或 `"false"`。
- **Touch**：`skill_file_ops_touch(path)` —— 缺失时创建空文件。

## POSIX 文件描述符操作
需要精细 I/O（seek、部分读写、truncate）时，在 `execute_javascript` 中直接使用 `fs` 命名空间：

    let fd = await fs.open("log.txt", "a+");
    await fs.write(fd, "new line\n");
    await fs.seek(fd, 0, "start");
    let head = await fs.read(fd, 100);
    await fs.close(fd);

打开标志：`"r"`、`"r+"`、`"w"`、`"w+"`、`"a"`、`"a+"`（兼容 Node）。
seek 的 whence：`"start"` | `"current"` | `"end"`（或 `0` | `1` | `2`）。

文件描述符仅在单次 `execute_javascript` 调用期间有效，调用结束时自动关闭 —— 但显式关闭是好习惯。
