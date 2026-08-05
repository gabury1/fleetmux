#!/usr/bin/env bash
# 마지막 프롬프트(last-<sid>) — 저장·정리·렌더.
#
# 이 파일이 지키는 것:
#   ① **부가물 원칙.** 파일이 없거나 깨졌거나 세션 id 를 못 받으면 프리뷰는 예전 출력을
#      **바이트 그대로** 낸다. 이 기능이 관제탑을 깨뜨리는 경로가 하나도 없어야 한다.
#   ② **이벤트 게이팅.** --hooks-json 은 UserPromptSubmit·PostToolUse·PreCompact·PostCompact 를,
#      --codex-hooks 는 UserPromptSubmit·PreToolUse·PostToolUse 를 전부 `--hook working` 하나로
#      묶는다. 그래서 $2 만 봐서는 프롬프트 제출인지 알 수 없다. 게이팅을 빼면 PostToolUse 의
#      tool_input.prompt(Task 도구 지시문)가 매 툴콜마다 사용자 프롬프트로 둔갑한다.
#   ③ **파서가 진짜 JSON 을 읽는다.** 따옴표·개행·\u 이스케이프·깊이 — tt_jv 의 정규식이
#      네 군데서 깨지던 자리를 전부 여기서 못박는다.
#   ④ **줄 수 회계.** 헤더가 먹은 줄만큼 화면 꼬리를 안 줄이면 프리뷰가 넘쳐 위가 잘린다 —
#      즉 방금 그린 프롬프트가 제일 먼저 사라진다.
#
# ⛔ tmux 는 PATH 앞의 가짜가 전부 가로챈다. 진짜 바이너리에 절대 안 닿는다.
set -u
. "$(dirname "$0")/lib.sh"
tt_test_sandbox

STATE="$HOME/.cache/tt"
mkdir -p "$STATE"
TAB=$'\t'
ESC=$'\033'

# ── ⛔ PATH 가드 — 어떤 단언보다 먼저 선다 ─────────────────────────────────
mkdir -p "$TTROOT/bin"
cat > "$TTROOT/bin/tmux" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TT_TMUX_LOG"
case "${1:-}" in
    ls)
        # 형식 문자열로 호출부를 가른다: 5필드=--list, 2필드=tt_sweep_hooks
        case "${3:-}" in
            *session_name*) [ -n "${TT_FAKE_LS5:-}" ] && printf '%s\n' "$TT_FAKE_LS5" ;;
            *)              [ -n "${TT_FAKE_LS2:-}" ] && printf '%s\n' "$TT_FAKE_LS2" ;;
        esac
        exit 0 ;;
    display-message) [ -n "${TT_FAKE_DISP:-}" ] && printf '%s\n' "$TT_FAKE_DISP"; exit 0 ;;
    capture-pane)    [ -n "${TT_FAKE_PANE:-}" ] && printf '%s\n' "$TT_FAKE_PANE"; exit 0 ;;
    list-panes)      printf '%s\n' "${TT_FAKE_PANECMD:-claude}"; exit 0 ;;
esac
exit 1
SHIM
chmod +x "$TTROOT/bin/tmux"
export TT_TMUX_LOG="$TTROOT/tmux-calls.log"
: > "$TT_TMUX_LOG"

# awk 호출을 세는 가짜 — 진짜 awk 로 그대로 넘긴다. "게이팅이 실제로 포크를 아낀다"는
# 주장은 코드를 읽어서가 아니라 이걸로 잰다(아래 ② 참조).
REALAWK=$(PATH=/usr/bin:/bin:/usr/local/bin command -v awk) || REALAWK=""
[ -n "$REALAWK" ] || { echo "awk 를 못 찾았다"; exit 1; }
export TT_AWK_LOG="$TTROOT/awk-calls.log"
: > "$TT_AWK_LOG"
cat > "$TTROOT/bin/awk" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$TT_AWK_LOG"
exec $REALAWK "\$@"
SHIM
chmod +x "$TTROOT/bin/awk"
export PATH="$TTROOT/bin:$PATH"
awk_calls() { grep -c 'utf8trim' "$TT_AWK_LOG" 2>/dev/null || true; }
export TMUX_PANE='%9'
export TT_FAKE_DISP="\$9${TAB}zz${TAB}$HOME${TAB}claude${TAB}1"
LF="$STATE/last-9"

hook() {   # $1=상태  $2=페이로드
    printf '%s' "${2:-}" | "$TTBIN" --hook "$1" >/dev/null 2>&1 || true
}
ups() {    # UserPromptSubmit 페이로드 한 벌. $1 = prompt 값(JSON 안에 들어갈 문자열 그대로)
    printf '{"session_id":"7f3b1c22-0000-4000-8000-0123456789ab","cwd":"%s",%s"prompt":"%s"}' \
        "$HOME" '"hook_event_name":"UserPromptSubmit",' "$1"
}
body() { tail -n +2 "$LF" 2>/dev/null || true; }
head1() { head -1 "$LF" 2>/dev/null || true; }

# ── ① 저장 ─────────────────────────────────────────────────────────────────
rm -f "$LF"
hook working "$(ups '첫 지시')"
assert_rc 0 test -f "$LF"
assert_eq "$(body)" "첫 지시" "UserPromptSubmit 의 프롬프트가 본문으로 들어간다"
case "$(head1)" in
    ''|*[!0-9]*) got=no ;;
    *) got=yes ;;
esac
assert_eq "$got" "yes" "1행은 기록 시각(epoch)이다"

# ★tt_jv 의 정규식이 통째로 깨지던 자리 — 값 안의 따옴표.
#   실측: {"prompt":"README 의 \"의존성\" 절"} 에서 tt_jv 는 `README 의 \` 한 조각만 뽑았다.
hook working "$(ups 'README 의 \"의존성\" 절을 고쳐줘')"
assert_eq "$(body)" 'README 의 "의존성" 절을 고쳐줘' "★값 안의 따옴표에서 안 잘린다"

# ★\n 을 실제 개행으로 푼다 — 안 풀면 "최대 3줄" 계산이 영영 1줄로 보인다
hook working "$(ups '1행\n2행\n3행')"
assert_eq "$(body | grep -c .)" "3" "★\\n 이 진짜 개행 3줄이 된다"

# 탭·역슬래시
hook working "$(ups 'C:\\tmp 를\t지워')"
assert_eq "$(body)" "C:\\tmp 를${TAB}지워" "\\\\ 와 \\t 를 푼다"

# ★제어문자(터미널 이스케이프)는 버린다 — 프리뷰로 흘러가면 화면이 깨진다
hook working "$(ups '\u001b[31m빨강\u001b[0m 지워줘')"
case "$(body)" in *"$ESC"*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "★ESC 가 본문에 남지 않는다"
assert_contains "$(body)" "빨강" "ESC 만 빠지고 글자는 남는다"

# \u 로 온 한글·이모지도 원문 그대로 복원된다(물음표 밭이 되면 안 된다)
hook working "$(ups '\uc548\ub155 \ud83d\ude00')"
assert_eq "$(body)" "안녕 😀" "\\u 이스케이프가 UTF-8 로 제대로 복원된다"

# ★깊이 1 만 본다 — 프롬프트 값 안에 붙여넣은 가짜 JSON 에 안 속는다
hook working "$(ups '이 페이로드 봐줘: {\"prompt\": \"가짜\"}')"
assert_eq "$(body)" '이 페이로드 봐줘: {"prompt": "가짜"}' "★값 안의 가짜 prompt 키에 안 속는다"

# ★깊이 1 만 본다 — 중첩 객체 안의 prompt 가 **먼저 나와도** 진짜가 이긴다.
#   순서로 이기는 게 아니라 깊이로 이겨야 한다. 깊이 제한을 풀면 앞에 나온 쪽이 이겨 버린다.
hook working '{"hook_event_name":"UserPromptSubmit","meta":{"prompt":"엉뚱한 것"},"prompt":"진짜 지시"}'
assert_eq "$(body)" "진짜 지시" "★중첩된 prompt 가 앞에 있어도 depth 1 의 것을 고른다"

# 생 제어문자가 값 안에 그대로 실려 와도(스펙상 잘못된 JSON 이지만 훅은 뭐든 받는다) 걸러낸다
hook working "$(ups "$ESC[31m생ESC$ESC[0m")"
case "$(body)" in *"$ESC"*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "★생 ESC 바이트도 본문에 남지 않는다"
assert_contains "$(body)" "생ESC" "그래도 글자는 남는다"

# ── ② 이벤트 게이팅 ────────────────────────────────────────────────────────
# ★PostToolUse 의 tool_input.prompt = Task 도구 서브에이전트 지시문. 훅 상태는 똑같이
#   working 이라 $2 로는 구별할 수 없다. 게이팅이 없으면 매 툴콜마다 이게 덮어쓴다.
hook working "$(ups '진짜 마지막 지시')"
hook working '{"hook_event_name":"PostToolUse","tool_name":"Task","tool_input":{"prompt":"서브에이전트 지시문"}}'
assert_eq "$(body)" "진짜 마지막 지시" "★PostToolUse 의 tool_input.prompt 는 마지막 프롬프트가 아니다"

# codex 의 PreToolUse 도 같은 working 갈래다
hook working '{"hook_event_name":"PreToolUse","tool_name":"shell","tool_input":{"prompt":"쉘 명령"}}'
assert_eq "$(body)" "진짜 마지막 지시" "PreToolUse 도 마지막 프롬프트를 안 건드린다"

# 파일이 아예 없던 상태에서도 안 만든다
rm -f "$LF"
hook working '{"hook_event_name":"PostToolUse","tool_input":{"prompt":"서브에이전트 지시문"}}'
assert_rc 1 test -f "$LF"

# 훅 상태 자체는 payload 와 무관하게 정상이어야 한다 — 부가물이 본업을 망치면 안 된다
assert_eq "$(cut -d' ' -f1 "$STATE/hook-9" 2>/dev/null || true)" "working" \
    "프롬프트를 안 뽑아도 훅 상태는 정상으로 남는다"
hook working ''
assert_eq "$(cut -d' ' -f1 "$STATE/hook-9" 2>/dev/null || true)" "working" \
    "빈 stdin 이어도 훅은 죽지 않는다"
assert_rc 1 test -f "$LF"

# ★게이팅은 정확성만이 아니라 **비용**이 목적이다. working 은 툴콜마다 오는 갈래라,
#   프롬프트 제출이 아닐 때 awk 를 부르면 훅 경로의 포크가 툴콜 수만큼 는다.
#   코드를 읽어서가 아니라 실제 awk 호출 수로 잰다.
: > "$TT_AWK_LOG"
hook working '{"hook_event_name":"PostToolUse","tool_input":{"prompt":"x"}}'
hook working '{"hook_event_name":"PreToolUse","tool_input":{"prompt":"x"}}'
hook working '{"hook_event_name":"PreCompact"}'
assert_eq "$(awk_calls)" "0" "★프롬프트 제출이 아니면 추출기 awk 를 아예 안 부른다 — 포크 0"
: > "$TT_AWK_LOG"
hook working "$(ups '부른다')"
assert_eq "$([ "$(awk_calls)" -gt 0 ] && echo yes || echo no)" "yes" \
    "프롬프트 제출일 때는 부른다"

# ── ③ 4096 바이트 상한 ─────────────────────────────────────────────────────
big=$(awk 'BEGIN { s = ""; for (i = 0; i < 3000; i++) s = s "가"; printf "%s", s }')
hook working "$(ups "$big")"
n=$(body | wc -c | tr -d ' ')
assert_eq "$([ "${n:-0}" -le 4096 ] && echo ok || echo "too big: $n")" "ok" \
    "★상한을 넘는 프롬프트는 4096 바이트에서 잘린다"
assert_contains "$(head1)" "trunc" "★잘렸다는 사실이 파일에 남는다"
# 잘라도 깨진 바이트로 끝나지 않는다(미완결 UTF-8 시퀀스 제거)
assert_rc 0 sh -c 'iconv -f UTF-8 -t UTF-8 < "$1" > /dev/null' _ "$LF"

# ── ④ 정리 ─────────────────────────────────────────────────────────────────
hook working "$(ups '지워질 것')"
assert_rc 0 test -f "$LF"
hook clear ''
assert_rc 1 test -f "$LF"

# sweep: 살아있는 세션 것은 남기고, 죽은 세션 것은 지운다.
#   판정 기준은 hook-* 과 **같은 것**이어야 한다 — 재부팅 후 tmux 가 session id 를 $0 부터
#   재발급하므로, 기준이 갈리면 죽은 세션의 프롬프트가 새 세션 프리뷰 맨 위에 걸린다.
export TT_FAKE_LS2="\$9${TAB}1"
echo "idle 1 $$" > "$STATE/hook-9"           # pid 가 살아 있다 = 정품
printf '1\n살아있는 세션\n' > "$LF"
echo "idle 1 $$" > "$STATE/hook-77"          # id 77 은 live 목록에 없다 = 고아
printf '1\n죽은 세션\n' > "$STATE/last-77"
hook boot ''
assert_rc 0 test -f "$LF"
assert_rc 1 test -f "$STATE/last-77"

# 유령: id 는 살아있는데 훅 파일이 그 세션 것이 아닌 경우(죽은 pid) → 같이 지운다
echo "idle 1 999999" > "$STATE/hook-9"       # 없는 pid
printf '1\n유령\n' > "$LF"
hook boot ''
assert_rc 1 test -f "$LF"
unset TT_FAKE_LS2

# ── ⑤ 렌더 ─────────────────────────────────────────────────────────────────
PANE=$'pane one\npane two\npane three'
export TT_FAKE_PANE="$PANE"
pv() { FZF_PREVIEW_LINES="${2:-40}" FZF_PREVIEW_COLUMNS="${3:-60}" "$TTBIN" --preview zz "$1" 2>/dev/null || true; }

# ★★ 파일이 없으면 **기능 추가 전과 바이트 동일**하다. 헤더도, 빈 줄 하나도 붙지 않는다.
rm -f "$LF"
assert_eq "$(pv 9)" "$PANE" "★파일이 없으면 프리뷰는 화면 꼬리 그대로다 — 바이트 동일"
assert_eq "$("$TTBIN" --preview zz 2>/dev/null || true)" "$PANE" "★세션 id 인자가 없어도 그대로다"
assert_eq "$(pv 'not-a-number')" "$PANE" "숫자가 아닌 id 를 받아도 그대로다"
# 깨진 파일 — 1행만 있거나 쓰레기여도 프리뷰는 안 깨진다
printf '1234567890\n' > "$LF"
assert_eq "$(pv 9)" "$PANE" "본문 없는 파일이면 헤더 없이 그대로다"

# 3줄 이하면 "… +N줄" 줄 자체가 없다
printf '1\n1행\n2행\n3행\n' > "$LF"
out=$(pv 9)
case "$out" in *"…"*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "3줄이면 남은 줄 표시가 아예 없다"
assert_eq "$(printf '%s\n' "$out" | head -1)" "❯ 1행" "첫 줄에 ❯ 가 붙는다"
assert_eq "$(printf '%s\n' "$out" | sed -n 2p)" "  2행" "이어지는 줄은 두 칸 들여쓴다"
assert_contains "$out" "pane three" "그 아래로 화면 꼬리가 이어진다"

# 3줄을 넘으면 "… +N줄"
printf '1\na\nb\nc\nd\ne\n' > "$LF"
out=$(pv 9)
assert_contains "$out" "… +2줄" "★3줄을 넘으면 남은 줄 수를 적는다"
assert_eq "$(printf '%s\n' "$out" | grep -c '^❯ ')" "1" "❯ 는 첫 줄에만 붙는다"

# 잘린 경우도 같은 자리에 드러낸다
printf '1 trunc\na\nb\nc\nd\n' > "$LF"
assert_contains "$(pv 9)" "… +1줄 (잘림)" "★잘렸다는 사실이 렌더에 드러난다"
printf '1 trunc\na\nb\n' > "$LF"
assert_contains "$(pv 9)" "… (잘림)" "남은 줄이 없어도 잘림은 드러낸다"

# ★폭 — 프리뷰 폭을 넘는 줄은 잘린다. 안 자르면 fzf 가 접어서 줄 수 회계가 어긋난다.
long=$(awk 'BEGIN { s = ""; for (i = 0; i < 200; i++) s = s "x"; printf "%s", s }')
printf '1\n%s\n' "$long" > "$LF"
# cols=30 → 본문 폭 28 → 마지막 한 칸은 … 자리 → x 27개까지만 들어간다(총 표시폭 30)
x27=$(awk 'BEGIN { s = ""; for (i = 0; i < 27; i++) s = s "x"; printf "%s", s }')
assert_eq "$(pv 9 40 30 | head -1)" "❯ $x27…" \
    "★긴 줄이 프리뷰 폭 안으로 잘린다 — 표시폭이 정확히 cols 다"

# 한글은 한 글자가 두 칸이다 — 바이트나 글자 수로 자르면 폭이 어긋난다.
#   cols=20 → 본문 폭 18 → 한 칸은 … 자리 → 가 8개(16칸)까지만 들어간다.
k=$(awk 'BEGIN { s = ""; for (i = 0; i < 20; i++) s = s "가"; printf "%s", s }')
printf '1\n%s\n' "$k" > "$LF"
assert_eq "$(pv 9 40 20 | head -1)" "❯ 가가가가가가가가…" "★한글은 두 칸으로 세서 자른다"

# ★줄 수 회계 — 헤더가 먹은 만큼 화면 꼬리가 줄어든다
export TT_FAKE_PANE=$(awk 'BEGIN { for (i = 1; i <= 20; i++) print "screen line " i }')
printf '1\na\nb\nc\nd\ne\n' > "$LF"
out=$(pv 9 10 60)
assert_eq "$(printf '%s\n' "$out" | grep -c .)" "10" "★프리뷰 총 줄 수가 FZF_PREVIEW_LINES 를 안 넘는다"
assert_contains "$out" "screen line 20" "화면 꼬리는 여전히 '가장 아래'를 보여준다"
assert_contains "$out" "❯ a" "헤더도 그대로 살아 있다"
# 헤더가 없을 때는 20줄 창을 통째로 쓴다(회계가 헤더에만 반응한다는 증거)
rm -f "$LF"
assert_eq "$(pv 9 10 60 | grep -c .)" "10" "헤더가 없으면 화면이 창을 다 쓴다"

# ── ⑥ 배선 — --list 가 주는 필드와 프리뷰가 받는 필드가 같은 것이어야 한다 ──
# 이게 어긋나면 프리뷰는 영영 파일을 못 찾는다(설계 문서가 놓쳤던 구멍이다).
export TT_FAKE_LS5="\$42${TAB}1700000000${TAB}0${TAB}-${TAB}zz"
row=$("$TTBIN" --list 2>/dev/null | head -1) || row=""
assert_eq "${row%%$TAB*}" "zz" "--list 의 1번 필드는 여전히 세션 이름이다"
assert_eq "${row##*$TAB}" "42" "★--list 의 3번 필드가 세션 id 다 — 에이전트 세션"
assert_eq "$(printf '%s' "$row" | tr -cd "$TAB" | wc -c | tr -d ' ')" "2" "필드는 정확히 셋이다"
# 도구 세션은 다른 printf 를 탄다 — 거기도 같이 실어야 프리뷰가 아무 행에서나 동작한다
TT_FAKE_PANECMD=bash
export TT_FAKE_PANECMD
row=$("$TTBIN" --list 2>/dev/null | head -1) || row=""
assert_eq "${row##*$TAB}" "42" "★도구 세션 행도 3번 필드에 세션 id 를 싣는다"
unset TT_FAKE_PANECMD TT_FAKE_LS5
assert_contains "$(cat "$TTBIN")" "--preview {1} {3}" "★fzf 가 그 3번 필드를 프리뷰에 넘긴다"
assert_contains "$(cat "$TTBIN")" "--with-nth=2" "표시는 2번 필드만 — id 는 화면에 안 샌다"

assert_no_tmux_mutation "이 파일이 살아있는 tmux 서버를 건드리지 않았다"

tt_test_done
