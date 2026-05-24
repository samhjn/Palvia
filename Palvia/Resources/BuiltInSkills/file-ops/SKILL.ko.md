---
display_name: 파일 작업
description: "고급 파일 작업: 복사, 이동, 디렉토리 관리, 풍부한 stat"
---

# 파일 작업 Skill

기본 `file_*` 도구로는 부족한 디렉토리 관리, 일괄 복사, 이동/이름 변경, 풍부한 메타데이터가 필요한 경우 이 Skill 을 설치하세요.

## 도구 사용 안내
- **디렉토리 생성**: `skill_file_ops_mkdir(path)` —— 중간 상위 디렉토리도 생성.
- **복사**: `skill_file_ops_cp(src, dest, recursive?)` —— `recursive` 기본값 true.
- **이동 / 이름 변경**: `skill_file_ops_mv(src, dest)`.
- **풍부한 메타데이터**: `skill_file_ops_stat(path)` —— JSON `{name,path,size,is_file,is_dir,is_image,mtime_ms,ctime_ms}` 반환.
- **디렉토리 트리**: `skill_file_ops_tree(path?, max_depth?)` —— 재귀적으로 나열.
- **존재 확인**: `skill_file_ops_exists(path)` —— `"true"` 또는 `"false"` 반환.
- **Touch**: `skill_file_ops_touch(path)` —— 없으면 빈 파일 생성.

## POSIX 파일 디스크립터 연산
세밀한 I/O (seek, 부분 읽기/쓰기, truncate) 가 필요하면 `execute_javascript` 에서 `fs` 네임스페이스를 직접 사용하세요:

    let fd = await fs.open("log.txt", "a+");
    await fs.write(fd, "new line\n");
    await fs.seek(fd, 0, "start");
    let head = await fs.read(fd, 100);
    await fs.close(fd);

열기 플래그: `"r"`, `"r+"`, `"w"`, `"w+"`, `"a"`, `"a+"` (Node 호환).
seek 의 whence: `"start"` | `"current"` | `"end"` (또는 `0` | `1` | `2`).

파일 디스크립터는 한 번의 `execute_javascript` 호출 내에서만 유효하며 호출 종료 시 자동으로 닫히지만, 명시적 close 는 좋은 습관입니다.
