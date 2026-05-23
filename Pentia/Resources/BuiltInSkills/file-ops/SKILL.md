---
name: File Ops
description: "Advanced file operations: copy, move, directory management, rich stat"
iclaw:
  version: "1.0"
  tags: [files, filesystem, utilities]
---
# File Ops Skill

Install this skill when you need directory management, batch copies,
moves/renames, or rich metadata beyond what the default `file_*` tools provide.

## When to use which tool
- **Create directory**: `skill_file_ops_mkdir(path)` — creates intermediate parents.
- **Copy**: `skill_file_ops_cp(src, dest, recursive?)` — `recursive` defaults to true.
- **Move / rename**: `skill_file_ops_mv(src, dest)`.
- **Rich metadata**: `skill_file_ops_stat(path)` — returns JSON `{name,path,size,is_file,is_dir,is_image,mtime_ms,ctime_ms}`.
- **Directory tree**: `skill_file_ops_tree(path?, max_depth?)` — recursive listing.
- **Check existence**: `skill_file_ops_exists(path)` — returns `"true"` or `"false"`.
- **Touch**: `skill_file_ops_touch(path)` — create an empty file if missing.

## POSIX file descriptor operations
For fine-grained I/O (seek, partial reads/writes, truncate), use `execute_javascript`
with the `fs` namespace directly:

    let fd = await fs.open("log.txt", "a+");
    await fs.write(fd, "new line\n");
    await fs.seek(fd, 0, "start");
    let head = await fs.read(fd, 100);
    await fs.close(fd);

Open flags: `"r"`, `"r+"`, `"w"`, `"w+"`, `"a"`, `"a+"` (Node-compatible).
Whence for seek: `"start"` | `"current"` | `"end"` (or `0` | `1` | `2`).

File descriptors are scoped to a single `execute_javascript` call and
auto-closed when that call ends — but closing explicitly is good hygiene.
