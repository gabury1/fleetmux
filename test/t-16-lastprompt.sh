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
CSI=$'\302\233'          # U+009B — 8비트 CSI. ESC 없이 혼자 커서를 움직인다.
BS='\'                   # JSON 이스케이프를 소스에 적을 때 쓴다("${BS}u009b" = 여섯 글자 )

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

# ── 표시폭 오라클 ──────────────────────────────────────────────────────────
# ★헤더의 폭 단언은 **글자 수가 아니라 표시폭**으로 재야 한다. 자를 자리를 정하는 건 터미널이
#   그리는 칸 수이지 글자 수가 아니고, 폭을 잘못 세면 우리가 붙인 … 자체가 fzf 에게 잘려
#   나가 "잘렸다"는 표시조차 안 남는다.
#   ⚠ src 의 wcw() 로 재면 **순환 논증**이다 — 폭 표가 틀리면 렌더도 검사도 똑같이 틀려
#   그대로 통과한다(그게 지금 고치는 버그다). 그래서 이 테스트는 자기 폭 표를 따로 들고
#   있다: EastAsianWidth 에서 **이 파일이 실제로 쓰는 글자만** 옮겨 적은 별개 구현이다.
#     구분선 ─(U+2500)·❯(U+276F)·…(U+2026)·ASCII = 1칸
#     한글 음절·한글 자모 확장-A(U+A960–A97C)·✅(U+2705)·❌(U+274C)·⭐(U+2B50)·⏰(U+23F0) = 2칸
DISPW_AWK='
    BEGIN { for (i = 1; i < 256; i++) O[sprintf("%c", i)] = i }
    {
        gsub(/\033\[[0-9;]*m/, "")
        L = length($0); p = 1; t = 0
        while (p <= L) {
            c = O[substr($0, p, 1)]
            if (c < 128)       { n = 1; v = c }
            else if (c >= 240) { n = 4; v = c - 240 }
            else if (c >= 224) { n = 3; v = c - 224 }
            else if (c >= 192) { n = 2; v = c - 192 }
            else               { n = 1; v = -1 }
            for (q = 1; q < n; q++) v = v * 64 + (O[substr($0, p + q, 1)] % 64)
            t += w(v); p += n
        }
        print t
    }
    function w(v) {
        if (v >= 44032 && v <= 55203) return 2      # 한글 음절
        if (v >= 43360 && v <= 43388) return 2      # 한글 자모 확장-A
        if (v == 9989  || v == 10060) return 2      # ✅ ❌
        if (v == 11088 || v == 9200)  return 2      # ⭐ ⏰
        return 1
    }'
dispw()      { LC_ALL=C awk "$DISPW_AWK"; }
strip_ansi() { LC_ALL=C awk '{ gsub(/\033\[[0-9;]*m/, ""); print }'; }
# N번째 줄의 표시폭 — 색 이스케이프를 벗기고 **칸을 실제로 센다**(글자 수가 아니다).
wof()     { printf '%s\n' "$1" | sed -n "${2}p" | dispw; }
# 줄들 중 가장 넓은 표시폭. cols 를 넘는 줄이 하나라도 있으면 여기서 드러난다.
maxw()    { printf '%s\n' "$1" | dispw | sort -n | tail -1; }
# N번째 줄의 글자. 색만 벗긴다 — 본문에는 접두가 없으니 떼어낼 것도 없다.
rowtext() { printf '%s\n' "$1" | strip_ansi | sed -n "${2}p"; }

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

# ★C1(U+0080–9F)도 버린다. ESC 만 거르면 부족하다 — 8비트 CSI(U+009B)는 ESC 없이 혼자
#   커서를 움직인다. UTF-8 로는 c2 9b 두 바이트라 "코드 < 32" 검사에 안 걸렸다(실측 잔존).
hook working "$(ups "${BS}u009b31m빨강${BS}u009b0m")"
case "$(body)" in *"$CSI"*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "★\\u009b(8비트 CSI)가 본문에 남지 않는다"
assert_contains "$(body)" "빨강" "C1 만 빠지고 글자는 남는다"
hook working "$(ups "${CSI}31m생CSI${CSI}0m")"
case "$(body)" in *"$CSI"*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "★생 C1 바이트(c2 9b)도 본문에 남지 않는다"
assert_contains "$(body)" "생CSI" "그래도 글자는 남는다"

# ── ①-b 권한 ───────────────────────────────────────────────────────────────
# ★이 파일에는 **사용자가 친 프롬프트 원문**이 들어간다 — ~/.cache/tt 에 대화 본문이 놓이는
#   건 이번이 처음이고, 같은 것을 담는 ~/.claude/projects 는 0700 이다. 이 기계에는 uid 가
#   둘 있다(1000·1001). umask 에 맡기면 022 에서 -rw-r--r--, 002 에서 -rw-rw-r-- 라
#   결과가 기계마다 갈린다 — 어느 umask 로 훅을 돌려도 0600 이어야 한다.
mode_of() { ls -ld "$1" 2>/dev/null | awk '{ printf "%s", substr($1, 1, 10) }'; }
oldmask=$(umask)
umask 000
rm -f "$LF"
hook working "$(ups '남이 읽으면 안 되는 지시')"
assert_eq "$(mode_of "$LF")" "-rw-------" "★umask 000 으로 훅을 돌려도 0600 이다"
# 예전 판이 남긴 헐거운 파일도 다음 쓰기에서 조여진다.
#   mv 는 rename 이라 tmp 의 모드를 그대로 옮긴다 — 그래서 이 단언은 **tmp 도 0600 이었다**는
#   증거이기도 하다(tmp 는 mv 전에도 본문이 다 들어 있어 그대로 읽힌다).
chmod 666 "$LF"
hook working "$(ups '두 번째 지시')"
assert_eq "$(mode_of "$LF")" "-rw-------" "★이미 헐거운 파일도 다음 쓰기에서 조여진다"
umask 022
hook working "$(ups '세 번째 지시')"
assert_eq "$(mode_of "$LF")" "-rw-------" "umask 022 에서도 결과가 같다"
umask "$oldmask"

# ── ①-c 남은 tmp 조각 ──────────────────────────────────────────────────────
# ★umask 는 **새로 만드는** 파일에만 걸린다. `> "$t"` 는 그 이름이 이미 있으면 열어서 자르기만
#   하고 예전 모드를 그대로 둔다 — mv 는 rename 이라 그 헐거운 모드가 목적지까지 따라간다.
#   조각(.last-<id>.<pid>)은 훅이 mv 전에 죽으면 남고 pid 는 재사용되므로, "이미 있는 이름"은
#   실제로 일어난다.
#
#   조각 이름에는 훅 프로세스의 $$ 가 박히는데 밖에서는 그 pid 를 알 수 없다. 그래서 저장
#   함수를 **이 셸 안으로 들여와** 부른다($$ = 이 셸). 들여오는 것은 bin/fmux 원문 그대로다 —
#   TT_LASTP_MAX 부터 tt_last_prompt_save 의 닫는 중괄호까지가 순수 정의라 부작용이 없다.
eval "$(sed -n '/^TT_LASTP_MAX=/,/^}$/p' "$TTBIN")"
assert_eq "$(command -v tt_last_prompt_save)" "tt_last_prompt_save" "저장 함수를 이 셸로 들여왔다"
rm -f "$LF"
frag="$STATE/.last-9.$$"
printf 'x' > "$frag"; chmod 666 "$frag"
oldmask=$(umask); umask 000
tt_last_prompt_save '$9' "$(ups '남은 조각 위에 쓴다')" 1700000000
umask "$oldmask"
assert_eq "$(mode_of "$LF")" "-rw-------" \
    "★★남은 조각을 재사용해도 0600 이다 — 서브셸 전에 unlink 한다"
assert_eq "$(body)" "남은 조각 위에 쓴다" "내용도 제대로 들어간다"
assert_rc 1 test -e "$frag"
unset -f tt_last_prompt_save

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

# ★쓰다 만 조각(.last-<id>.<pid>) 회수. 훅이 mv 에 닿기 전에 죽으면 남는다.
#   판정은 이름에 박힌 pid — 그 프로세스가 없으면 이 조각은 영영 완성되지 않는다.
#   살아있는 pid 는 건드리지 않는다: 지금 쓰는 중이면 지운 순간 mv 가 실패해 프롬프트가 샌다.
echo "idle 1 $$" > "$STATE/hook-9"
printf '1\n살아있는 세션\n' > "$LF"
printf 'x' > "$STATE/.last-9.999999"      # 없는 pid = 완성될 일 없는 조각
printf 'x' > "$STATE/.last-9.$$"          # 살아있는 pid = 쓰는 중일 수 있다
printf 'x' > "$STATE/.last-9.pid없음"     # 우리 형식이 아니다
hook boot ''
assert_rc 1 test -f "$STATE/.last-9.999999"      # 죽은 pid 의 조각 → 회수
assert_rc 0 test -f "$STATE/.last-9.$$"          # 살아있는 pid 의 조각 → 그대로
assert_rc 1 test -f "$STATE/.last-9.pid없음"     # 형식 밖 → 회수
assert_rc 0 test -f "$LF"                        # 조각을 쓸어도 진짜 파일은 남는다
rm -f "$STATE/.last-9.$$"
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

# ── ⑤-a 헤더 구조 ─────────────────────────────────────────────────────────
# ★사용자가 세 판 만에 고른 모양이다. 이 순서와 이 줄 수가 곧 계약이다:
#     last prompt ❯     ← 라벨 한 줄. 셸 프롬프트처럼 읽힌다(dim + accent)
#     첫 줄             ← 본문은 **다음 줄부터, 접두 없이** 창 폭 전체를 쓴다
#     둘째 줄
#     ──────────        ← 구분선 하나(dim + accent, 폭 = cols)
#     pane one          ← 여기부터 기존 화면 꼬리
#   중간 판이던 박스·세로선은 "못생겼다"로 명시적으로 버려졌다. 아래 폐기 단언이 부활을 막는다.
printf '1\n첫 줄\n둘째 줄\n' > "$LF"
out=$(pv 9 40 44)
assert_eq "$(rowtext "$out" 1)" "last prompt ❯" "★1행은 라벨 줄이다 — 셸 프롬프트처럼 읽힌다"
assert_eq "$(rowtext "$out" 2)" "첫 줄"   "★본문은 2행부터 — 접두 없이 왼쪽 끝에서 시작한다"
assert_eq "$(rowtext "$out" 3)" "둘째 줄" "둘째 본문 줄"
assert_eq "$(rowtext "$out" 4)" \
    "$(awk 'BEGIN { s = ""; for (i = 0; i < 44; i++) s = s "─"; print s }')" \
    "★본문 아래는 가로 구분선 하나다"
assert_eq "$(wof "$out" 4)" "44" "★★구분선의 표시폭을 실제로 세면 정확히 cols(44)다"
assert_eq "$(wof "$out" 1)" "13" "라벨 줄의 표시폭 = ❯ 포함 13칸"
assert_eq "$(printf '%s\n' "$out" | sed -n 5p)" "pane one" "★화면 꼬리는 손대지 않는다 — 바이트 그대로"
assert_contains "$out" "pane three" "헤더 아래로 화면 꼬리가 이어진다"

# ★폐기된 안이 되살아나면 여기서 잡는다 — 박스·세로선·반전바.
hdr4=$(printf '%s\n' "$out" | head -4)
for ch in '╭' '╮' '╰' '╯' '│' '┃' '▌' '█'; do
    case "$hdr4" in *"$ch"*) got=yes ;; *) got=no ;; esac
    assert_eq "$got" "no" "폐기된 장식이 없다 [$ch]"
done
case "$hdr4" in *"$ESC[7m"*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "반전바(ESC[7m)도 안 쓴다"

# 색: accent 설정을 따르고, 라벨·구분선 **둘 다** dim 이다(본문이 읽혀야 한다)
case "$(printf '%s\n' "$out" | sed -n 1p)" in "$ESC[2;38;5;73m"*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "yes" "★라벨은 dim(2) + accent 기본값(73)으로 시작한다"
case "$(printf '%s\n' "$out" | sed -n 4p)" in "$ESC[2;38;5;73m"*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "yes" "★구분선도 dim + accent 다 — 장식이 본문보다 밝으면 안 된다"
case "$(printf '%s\n' "$out" | sed -n 2p)" in *"$ESC["*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "본문에는 우리가 색을 안 입힌다"
TT_ACCENT=200; export TT_ACCENT
out200=$(pv 9 40 44)
unset TT_ACCENT
assert_contains "$out200" "$ESC[2;38;5;200m" "★accent 를 바꾸면 라벨·구분선 색도 따라간다"
case "$out200" in *"$ESC[2;38;5;73m"*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "기본값 73 이 하드코딩으로 남아 있지 않다"

# 3줄이면 "… +N줄" 줄 자체가 없다 — 본문 예산 3줄을 본문이 다 쓴다
printf '1\n1행\n2행\n3행\n' > "$LF"
out=$(pv 9)
case "$out" in *"…"*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "3줄이면 남은 줄 표시가 아예 없다"
assert_eq "$(printf '%s\n' "$out" | sed -n 6p)" "pane one" "헤더는 라벨 1 + 본문 3 + 구분선 1 = 5줄이다"

# 3줄을 넘으면 "… +N줄" — 그 줄도 본문 예산 한 줄을 먹으므로 본문은 2줄까지다
printf '1\na\nb\nc\nd\ne\nf\n' > "$LF"
out=$(pv 9 40 44)
assert_eq "$(rowtext "$out" 4)" "… +4줄" "★3줄을 넘으면 본문 2줄 + 남은 줄 수를 적는다"
assert_eq "$(rowtext "$out" 5)" \
    "$(awk 'BEGIN { s = ""; for (i = 0; i < 44; i++) s = s "─"; print s }')" \
    "그래도 구분선은 마지막 한 줄이다"
assert_eq "$(printf '%s\n' "$out" | head -6 | tail -1)" "pane one" "라벨 1 + 본문 3 + 구분선 1 = 정확히 5줄"
case "$(printf '%s\n' "$out" | sed -n 4p)" in "$ESC[2m"*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "yes" "'… +N줄' 은 dim — 본문이 아니라 표시다"

# 잘린 경우도 같은 자리에 드러낸다
printf '1 trunc\na\nb\nc\nd\n' > "$LF"
assert_eq "$(rowtext "$(pv 9 40 44)" 4)" "… +2줄 (잘림)" "★잘렸다는 사실이 렌더에 드러난다"
printf '1 trunc\na\nb\n' > "$LF"
out=$(pv 9 40 44)
assert_eq "$(rowtext "$out" 4)" "… (잘림)" "★4096 상한에 걸린 것도 같은 자리에 드러낸다"
assert_eq "$(printf '%s\n' "$out" | head -6 | tail -1)" "pane one" "잘림 표시가 있어도 헤더는 5줄을 안 넘는다"

# ★폭 — 프리뷰 폭을 넘는 줄은 우리가 먼저 자른다. 안 자르면 fzf 가 **말없이** 잘라
#   우리가 붙인 … 까지 사라진다 = "뒤가 더 있다"는 표시조차 안 남는다.
long=$(awk 'BEGIN { s = ""; for (i = 0; i < 200; i++) s = s "x"; printf "%s", s }')
printf '1\n%s\n' "$long" > "$LF"
# cols=30, 접두 없음 → 마지막 한 칸은 … 자리 → x 29개 + … = 정확히 30칸
x29=$(awk 'BEGIN { s = ""; for (i = 0; i < 29; i++) s = s "x"; printf "%s", s }')
out=$(pv 9 40 30)
assert_eq "$(rowtext "$out" 2)" "$x29…" "★긴 줄이 프리뷰 폭 안으로 잘린다"
assert_eq "$(wof "$out" 2)" "30" "★★잘린 본문 줄의 표시폭이 정확히 cols(30)다"
assert_eq "$(maxw "$hdr4")" "44" "헤더 어느 줄도 cols 를 넘지 않는다"

# 한글은 한 글자가 두 칸이다 — 바이트나 글자 수로 자르면 폭이 어긋난다.
#   cols=20, 접두 없음 → … 자리 한 칸을 빼면 19칸 → 가 9개(18칸) + … = 19칸.
#   넓은 글자는 한 칸을 쪼갤 수 없어 20 에 한 칸 못 미친다 — 넘지 않는 게 계약이다.
k=$(awk 'BEGIN { s = ""; for (i = 0; i < 20; i++) s = s "가"; printf "%s", s }')
printf '1\n%s\n' "$k" > "$LF"
out=$(pv 9 40 20)
assert_eq "$(rowtext "$out" 2)" "가가가가가가가가가…" "★한글은 두 칸으로 세서 자른다"
assert_eq "$(wof "$out" 2)" "19" "★★한글 줄의 표시폭을 실제로 세면 19칸 — cols(20)을 안 넘는다"

# ★너무 좁으면 헤더를 통째로 포기한다 — 못 그릴 바엔 없는 게 낫다(부가물 원칙).
#   경계는 라벨 폭(13)이다. 라벨을 자르며 시작하는 헤더는 헤더 구실을 못 한다.
export TT_FAKE_PANE="$PANE"
printf '1\n짧은 지시\n' > "$LF"
assert_eq "$(pv 9 40 12)" "$PANE" "★cols<13 이면 헤더를 안 그리고 예전 프리뷰 그대로 낸다"
assert_eq "$(pv 9 40 0)" "$PANE" "cols 가 0 이어도 안 깨진다"
out=$(pv 9 40 13)
assert_eq "$(rowtext "$out" 1)" "last prompt ❯" "cols=13 은 그린다 — 경계 바로 위"
assert_eq "$(wof "$out" 1)" "13" "그 폭에서 라벨이 딱 맞아떨어진다"

# ── ⑤-b 렌더 소독 — 저장을 안 거친 파일이 들어와도 헤더가 안 깨진다 ─────────
# 손으로 만든 파일·옛 판이 남긴 파일은 저장 소독을 안 거쳤다. 렌더는 파일을 믿지 않는다.
#
# ★탭. 폭 1 로 세던 판을 실측했더니 20칸 한도에서 58칸이 나갔다 — 터미널이 탭을 탭 스톱까지
#   벌리는데 우리는 1칸으로 셌기 때문이다. 공백으로 펴서 센 폭과 그린 폭을 같게 만든다.
printf '1\na%sb%sc\n' "$TAB" "$TAB" > "$LF"
assert_eq "$(rowtext "$(pv 9 40 20)" 2)" "a b c" "★렌더가 탭을 공백 한 칸으로 편다"
tabline=$(awk -v t="$TAB" 'BEGIN { s = ""; for (i = 0; i < 40; i++) s = s t "x"; printf "%s", s }')
printf '1\n%s\n' "$tabline" > "$LF"
out=$(pv 9 40 20)
assert_eq "$(wof "$out" 2)" "20" "★★탭이 든 줄도 표시폭이 정확히 cols(20) 다"
case "$(printf '%s\n' "$out" | head -3)" in *"$TAB"*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "탭 자체가 프리뷰로 나가지 않는다"

# ★C1(U+0080–9F). 8비트 CSI(U+009B)는 ESC 없이 커서를 움직인다 — 프리뷰가 깨지면 사용자
#   눈에는 팝업 전체가 망가진 것으로 보인다. 저장 소독을 안 거친 파일에서도 막는다.
printf '1\n%s31m빨강%s0m\n' "$CSI" "$CSI" > "$LF"
out=$(pv 9 40 60)
case "$out" in *"$CSI"*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "★렌더가 C1(c2 9b)을 걷어낸다"
assert_contains "$out" "빨강" "C1 만 빠지고 글자는 남는다"
assert_eq "$(rowtext "$out" 2)" "31m빨강0m" "C1 두 바이트만 빠지고 나머지는 그대로다"
assert_eq "$(wof "$out" 2)" "9" "★C1 을 걷어낸 줄의 표시폭 = \"31m\" 3 + 빨강 4 + \"0m\" 2 = 9칸"
# 라벨·구분선은 색 이스케이프로 그리므로 전체 출력에는 ESC 가 원래 있다 — 벗겨 낸 본문만 본다
printf '1\n%s[31m생ESC\n' "$ESC" > "$LF"
out=$(pv 9 40 60)
case "$(printf '%s\n' "$out" | sed -n 2p | strip_ansi)" in *"$ESC"*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "★렌더가 생 ESC 도 걷어낸다"
assert_eq "$(rowtext "$out" 2)" "[31m생ESC" "ESC 만 빠지고 나머지는 그대로다"

# ── ⑤-c 폭 표 — 빠져 있던 넓은 글자 ────────────────────────────────────────
# ★실측: `✅`×30 @cols=20 이 37칸으로 나갔다. wcw() 의 이모지 구간이 `v >= 127744`(U+1F300)
#   부터라, BMP 에 사는 ✅(U+2705)·❌(U+274C)·⭐(U+2B50)·⏰(U+23F0)과 한글 자모 확장-A
#   (U+A960–A97C)가 통째로 1칸으로 세어졌다. 그냥 "줄이 길어지는" 문제가 아니다 —
#   우리가 붙인 … 자체가 폭 밖으로 밀려 fzf 에게 잘리므로 **잘렸다는 표시조차 안 남는다**.
#   바이트로 적는다 — bash 3.2 에는 $'\uXXXX' 가 없다(맥 기본 셸).
EMO_OK='\342\234\205'      # ✅ U+2705
EMO_X='\342\235\214'       # ❌ U+274C
EMO_STAR='\342\255\220'    # ⭐ U+2B50
EMO_CLOCK='\342\217\260'   # ⏰ U+23F0
JAMO_A='\352\245\240'      # ꥠ U+A960 — 한글 자모 확장-A
for pair in "$EMO_OK ✅ U+2705" "$EMO_X ❌ U+274C" "$EMO_STAR ⭐ U+2B50" \
            "$EMO_CLOCK ⏰ U+23F0" "$JAMO_A ꥠ U+A960"; do
    set -- $pair
    oct="$1"; sym="$2"; cp="$3"
    line=$(awk -v c="$(printf "$oct")" 'BEGIN { s = ""; for (i = 0; i < 30; i++) s = s c; printf "%s", s }')
    printf '1\n%s\n' "$line" > "$LF"
    out=$(pv 9 40 20)
    # 두 칸짜리 글자 9개(18칸) + … = 19칸. 폭 표가 1칸으로 세면 39칸이 나간다.
    assert_eq "$(wof "$out" 2)" "19" \
        "★★$sym($cp)×30 @cols=20 — 첫 본문 줄의 표시폭을 실제로 세면 19칸(cols 를 안 넘는다)"
    assert_eq "$(rowtext "$out" 2)" \
        "$(awk -v c="$(printf "$oct")" 'BEGIN { s = ""; for (i = 0; i < 9; i++) s = s c; print s "…" }')" \
        "$sym 는 9개까지만 들어가고 … 가 붙는다"
done
# 섞어 놔도 마찬가지다 — 자를 위치가 글자 경계와 안 맞으면 바로 드러난다.
#   넓은 글자는 한 칸을 쪼갤 수 없으므로 cols 에 한 칸 못 미칠 수 있다. 계약은
#   "cols 를 넘지 않고, 한 칸 이내로 꽉 찬다"이다 — 폭 표가 틀리면 곧바로 두 배 가까이 넘친다.
fits() {   # $1=프리뷰 출력  $2=cols
    _w=$(wof "$1" 2)
    if [ "$_w" -le "$2" ] && [ "$_w" -ge $(($2 - 1)) ]; then echo ok; else echo "$_w vs cols=$2"; fi
}
mixed=$(awk -v a="$(printf "$EMO_OK")" -v b="$(printf "$EMO_X")" -v c="$(printf "$JAMO_A")" \
    'BEGIN { s = ""; for (i = 0; i < 12; i++) s = s a "가" b "x" c; printf "%s", s }')
printf '1\n%s\n' "$mixed" > "$LF"
for c in 20 21 33 44 80; do
    assert_eq "$(fits "$(pv 9 40 "$c")" "$c")" "ok" \
        "★넓은 글자와 한글·ASCII 를 섞어도 cols=$c 를 안 넘고 한 칸 이내로 채운다"
done

# ── ⑤-d decode — 못 읽는 바이트는 한 바이트만 먹는다 ───────────────────────
# ★`0xC2` 다음에 사용자가 친 글자가 오면 예전 판은 그 글자까지 삼켰다(실측).
#   v = 2*64 + (65 % 64) = 129 → C1 그물(128–159)에 걸리고 CPLEN=2 라 A 가 사라진다.
printf '1\n\302ABCDE\n' > "$LF"
assert_eq "$(rowtext "$(pv 9 40 40)" 2)" "ABCDE" \
    "★★0xC2 뒤의 A 가 사라지지 않는다 — 깨진 선행 바이트만 버린다"
# 잘못된 선행 바이트 — 0xC0·0xC1(과잉 인코딩)·0xF5–0xFF(범위 밖). 정상 다바이트로 취급하면
#   뒤 글자를 1~3개씩 데려간다(0xC0 + "X" → v=24 로 C0 취급 → X 까지 증발).
printf '1\n\300X\301Y\365Z\377W\n' > "$LF"
assert_eq "$(rowtext "$(pv 9 40 40)" 2)" "XYZW" \
    "★★0xC0·0xC1·0xF5·0xFF 은 정상 선행 바이트가 아니다 — 뒤 글자를 안 데려간다"
# ★위 한 줄만으로는 **선행 바이트 검사**를 못 잰다 — 뒤가 연속 바이트가 아니라서 연속 바이트
#   검사가 먼저 잡아 준다(변이 실험으로 확인: `c < 192` 로 되돌려도 위 단언은 통과했다).
#   뒤에 진짜 연속 바이트를 붙여야 선행 바이트 검사만 남는다.
#     0xC0 0xA0 → 과잉 인코딩. 예전 판은 v=32(공백)로 계산해 **깨진 두 바이트를 그대로** 뱉었다.
#     0xC1 0xA0 → v=96('`') 로 계산돼 역시 그대로 나갔다.
#     0xF5 0x80 0x80 0x80 → v=1310720 (U+10FFFF 초과) 로 계산돼 네 바이트가 그대로 나갔다.
for bad in '\300\240' '\301\240' '\365\200\200\200'; do
    printf "1\nA${bad}B\n" > "$LF"
    out=$(pv 9 40 40)
    assert_eq "$(rowtext "$out" 2)" "AB" \
        "★★뒤가 연속 바이트여도 잘못된 선행 바이트는 버린다 [$bad]"
done
# 3바이트 선행 뒤가 연속 바이트가 아니면 1바이트로 처리한다
printf '1\n\340AB\n' > "$LF"
out=$(pv 9 40 40)
assert_eq "$(rowtext "$out" 2)" "AB" "★뒤가 연속 바이트가 아닌 0xE0 은 혼자 버려진다"
case "$(printf '%s\n' "$out" | sed -n 2p)" in *$'\340'*) got=yes ;; *) got=no ;; esac
assert_eq "$got" "no" "깨진 선행 바이트가 프리뷰로 새지 않는다"
# 잘린 시퀀스(줄 끝에서 끊긴 선행 바이트)도 같은 그물
printf '1\nOK\342\234\n' > "$LF"
out=$(pv 9 40 40)
assert_eq "$(rowtext "$out" 2)" "OK" "잘린 UTF-8 꼬리는 통째로 버린다"
assert_eq "$(wof "$out" 2)" "2" "깨진 바이트가 폭 계산에 유령 칸을 남기지 않는다"
assert_eq "$(maxw "$(printf '%s\n' "$out" | head -3)")" "40" "구분선은 여전히 정확히 cols 다"
# 진짜 U+FFFD 는 3바이트로 온전하므로 살아남는다 — 깨진 조각 판정과 헷갈리면 안 된다
printf '1\nA\357\277\275B\n' > "$LF"
assert_eq "$(rowtext "$(pv 9 40 40)" 2)" "$(printf 'A\357\277\275B')" "온전한 U+FFFD 는 글자로 남는다"

# ★줄 수 회계 — 헤더가 먹은 만큼 화면 꼬리가 줄어든다
export TT_FAKE_PANE=$(awk 'BEGIN { for (i = 1; i <= 20; i++) print "screen line " i }')
printf '1\na\nb\nc\nd\ne\n' > "$LF"
out=$(pv 9 10 60)
assert_eq "$(printf '%s\n' "$out" | grep -c .)" "10" "★프리뷰 총 줄 수가 FZF_PREVIEW_LINES 를 안 넘는다"
assert_contains "$out" "screen line 20" "화면 꼬리는 여전히 '가장 아래'를 보여준다"
assert_eq "$(rowtext "$out" 2)" "a" "헤더도 그대로 살아 있다"
# ★예산: 라벨 1 + 본문 3(= 본문 2 + "… +N줄") + 구분선 1 = 5줄이 화면 몫에서 빠진다. 5+5=10.
assert_eq "$(printf '%s\n' "$out" | sed -n 6p)" "screen line 16" \
    "★헤더가 정확히 5줄을 먹고 화면은 나머지 5줄을 쓴다"
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
