# claude-at

macOS launchd 기반 Claude Code CLI 세션 예약 도구.

## Release

릴리스할 때는 `make release V=x.y.z`를 사용할 것.
이 명령이 VERSION 상수 bump → 커밋 → 태그 → push를 한 번에 처리하고,
GitHub Actions가 자동으로 Release 생성 + Homebrew formula 업데이트를 수행함.

절대 수동으로 태그를 만들거나 VERSION 상수를 직접 수정하지 말 것.
