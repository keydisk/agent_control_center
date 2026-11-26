#!/bin/bash
# Stop 훅: 마지막으로 통과한 뒤 변경이 있으면 테스트를 돌리고, 실패하면 로그를 Claude에게 돌려줍니다.
# stop_hook_active로 통과시키지 않습니다. 반복은 Claude Code의 연속 차단 한도가 끊습니다.
state="$(git rev-parse --git-path claude-verified)" || exit 0
current="$( {
  git rev-parse HEAD
  git diff HEAD
  git ls-files -o --exclude-standard -z | xargs -0 shasum
} 2>/dev/null | shasum )"
[ "$(cat "$state" 2>/dev/null)" = "$current" ] && exit 0

if output="$(flutter test 2>&1)"; then
  printf '%s' "$current" > "$state"
  exit 0
fi
printf '테스트가 실패했습니다. 고친 뒤 끝내세요.\n%s\n' "$(printf '%s\n' "$output" | tail -n 80)" >&2
exit 2
