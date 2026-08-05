#!/usr/bin/env bash
# bash 3.2 계약 — 맥 기본 /bin/bash 에서 죽는 문법이 하나라도 들어오면 여기서 터진다.
#
# 왜 이 파일이 생겼나(2026-08-05, 팀 배포 게이트 B6):
#   src/50-hook.sh 에 `${payload,,}` 가 있었다. bash 4.0 전용 문법이고, 맥 기본 셸은 3.2 다.
#   **파싱은 통과하고 확장 시점에 죽기 때문에** 증상이 조용하다 — 설치도 되고 목록도 뜨는데
#   ⏸(승인 대기)만 영영 안 뜬다. README·SKILL 이 둘 다 "the one that matters"라고 못박은
#   바로 그 신호가, 아무 에러 없이 사라진다. 이 기계(리눅스·bash 5)에서는 전 테스트가
#   통과하므로 **동작 테스트로는 절대 못 잡는다.** 그래서 문법을 정적으로 훑는다.
#
# 검사 대상은 "팀원 기계에서 도는 것" 전부다: bin/fmux 의 재료(src/*.sh), 설치기, PATH shim.
# 전줄 주석(^#)은 뺀다 — 05-config.sh 는 "${var^^} 는 없다"라고 **적어 두는** 것이 옳고,
# 그 문장을 못 쓰게 만들면 다음 사람이 이유를 모른 채 같은 실수를 한다.
set -u
. "$(dirname "$0")/lib.sh"
tt_test_sandbox
cd "$(dirname "$0")/.." || exit 1

# 금지 문법 → 사람이 읽는 이름. 셋 다 "3.2 에서 죽는다"가 이유다.
#   ${v,,} ${v^^}  대소문자 변환      → tr '[:upper:]' '[:lower:]' 로 쓴다(05-config.sh 관례)
#   declare -A     연관배열           → "\n<키>\t<값>" 줄 표 + case 글롭(80-view.sh 관례)
#   mapfile/readarray                 → while IFS= read -r 루프
PAT_LOWER='\$\{[A-Za-z_][A-Za-z0-9_]*,,'
PAT_UPPER='\$\{[A-Za-z_][A-Za-z0-9_]*\^\^'
PAT_ASSOC='(declare|typeset|local)[[:space:]]+-[A-Za-z]*A'
PAT_MAPF='(^|[^-A-Za-z_])(mapfile|readarray)[[:space:]]'

# 전줄 주석을 뺀 본문만 훑는다.
code_of() { grep -v '^[[:space:]]*#' "$1"; }

scan() {   # $1=파일  $2=정규식  → 걸린 줄(파일:줄번호 포함)
    code_of "$1" | grep -nE "$2" | sed "s|^|$1: |" || true
}

FILES=$(ls src/*.sh install.sh libexec/claude libexec/codex 2>/dev/null)

for f in $FILES; do
    assert_eq "$(scan "$f" "$PAT_LOWER")" "" "$f 에 bash4 전용 \${v,,} 가 없다"
    assert_eq "$(scan "$f" "$PAT_UPPER")" "" "$f 에 bash4 전용 \${v^^} 가 없다"
    assert_eq "$(scan "$f" "$PAT_ASSOC")" "" "$f 에 연관배열 선언이 없다"
    assert_eq "$(scan "$f" "$PAT_MAPF")"  "" "$f 에 mapfile·readarray 가 없다"
done

# 산출물도 같이 본다 — src 를 고치고 make 를 안 돌리면 팀원이 받는 파일은 옛 문법 그대로다.
for p in "$PAT_LOWER" "$PAT_UPPER" "$PAT_ASSOC" "$PAT_MAPF"; do
    assert_eq "$(scan bin/fmux "$p")" "" "bin/fmux 에 bash4 전용 문법이 없다"
done

# ── 그물이 진짜인지 자기검사 ────────────────────────────────────────────────
# 정규식이 오타 하나로 아무것도 안 잡는 그물이 되면, 이 파일은 영원히 초록불만 켠다.
# 그래서 "잡혀야 하는 것"을 일부러 만들어 한 번 잡아본다.
BAIT="$TTROOT/bait.sh"
cat > "$BAIT" <<'EOF'
# 이 줄은 주석이라 안 잡혀야 한다: ${v,,} ${v^^} declare -A mapfile
x=${payload,,}
y=${name^^}
declare -A tbl
mapfile -t lines < f
EOF
assert_contains "$(scan "$BAIT" "$PAT_LOWER")" 'x=${payload,,}' "그물이 \${v,,} 를 실제로 잡는다"
assert_contains "$(scan "$BAIT" "$PAT_UPPER")" 'y=${name^^}'    "그물이 \${v^^} 를 실제로 잡는다"
assert_contains "$(scan "$BAIT" "$PAT_ASSOC")" 'declare -A tbl' "그물이 연관배열을 실제로 잡는다"
assert_contains "$(scan "$BAIT" "$PAT_MAPF")"  'mapfile -t'     "그물이 mapfile 을 실제로 잡는다"
# 그리고 주석 줄은 안 잡는다 — 안 그러면 "왜 쓰면 안 되는지"를 못 적게 된다.
assert_eq "$(scan "$BAIT" "$PAT_LOWER" | grep -c '이 줄은 주석' || true)" "0" "전줄 주석은 그물에 안 걸린다"

tt_test_done
