# ── 마지막 프롬프트 (last-<sid>) ────────────────────────────────────────────
# 프리뷰 맨 위에 "이 세션한테 내가 뭘 시켰더라"를 고정으로 띄우기 위한 재료.
# 화면은 안 긁는다 — UserPromptSubmit 훅 payload 안에 프롬프트 본문이 그대로 들어 있다.
# 훅은 이미 그 payload 를 stdin 으로 받아 파싱하고 있으니, 재료가 손에 있는 셈이다.
#
# 이 기능은 **부가물**이다. 여기서 무엇이 실패하든 프리뷰·상태 판정·매니페스트에 번지면
# 안 된다. 그래서 아래 함수는 어떤 경로로도 0 만 반환하고, 렌더 쪽은 헤더를 못 만들면
# 그냥 예전 프리뷰를 그대로 낸다.
#
# ── 왜 tt_jv 를 안 쓰나 (실측) ─────────────────────────────────────────────
# tt_jv 의 정규식은 "값 안에 따옴표가 없다"는 전제다. session_id·cwd 에는 맞지만
# 프롬프트에는 네 군데가 깨진다. 전부 재현해 봤다:
#   ① {"prompt":"README 의 \"의존성\" 절"} → 뽑히는 값이 `README 의 \` 한 조각뿐이다.
#      문자 클래스 [^"]* 가 \" 의 " 에서 멈춘다. 프리뷰가 통째로 무의미해진다.
#   ② \n 을 안 푼다 → 개행이 아니라 백슬래시+n 두 글자. "최대 3줄" 계산이 성립하지 않는다.
#   ③ \uXXXX 를 안 푼다 → ESC 가 문자열로 남는다. 훅이 받는 건 사용자 입력이라,
#      제어문자를 실제로 풀어 놓으면 그게 프리뷰를 깨뜨린다(그래서 아래에서 버린다).
#   ④ 깊이 개념이 없다 → PostToolUse 의 tool_input.prompt(Task 도구 서브에이전트 지시문)를
#      프롬프트로 오인한다. 이건 이론이 아니다: --hooks-json 은 UserPromptSubmit·PostToolUse·
#      PreCompact·PostCompact 를 **전부 `--hook working` 하나로** 묶고, --codex-hooks 도
#      UserPromptSubmit·PreToolUse·PostToolUse 를 working 으로 묶는다. $2 만 봐서는
#      프롬프트 제출인지 알 수 없으므로, 매 툴콜마다 오탐이 난다.
# tt_jv 자체는 손대지 않는다 — 그쪽 용도로는 정상이고, 훅 경로의 포크 0 을 지킨다.
# 프롬프트만 전용 스캐너로 뽑는다.
#
# ── 왜 jq 가 아니라 awk 인가 ────────────────────────────────────────────────
# jq 는 이 저장소의 의존성이 아니다. install.sh 의 게이트가 검사하는 건 bash·tmux·fzf·awk
# 넷과 flock·make(선택)뿐이고, src/ 전체에 jq 호출이 0건이다(60-rc.sh 는 오히려 "jq도
# 포크도 없이"라고 규율을 적어 뒀다). jq 를 쓰면 없는 기계에서 **이 기능만 조용히 안 뜨는**
# 실패가 된다. awk 는 이미 필수 의존성이다.
#
# ── awk 문법 제약 ──────────────────────────────────────────────────────────
# 파이 기본은 mawk 1.3.4, 맥은 BSD awk 다. gensub·다중문자 RS·match() 배열인자·mktime·
# 16진 리터럴을 안 쓴다(TT_ACT_AWK·TT_MF_CHECK_AWK 과 같은 규율).
# LC_ALL=C 로 부른다 — 스캐너가 다루는 구조 문자는 전부 ASCII 이고, 한글은 그냥 바이트로
# 통과시키면 된다. 그래야 length/substr 이 어느 awk 에서나 **바이트** 단위로 같게 동작하고,
# 4096"바이트" 상한도 구현에 안 흔들린다.

TT_LASTP_MAX=4096      # 저장 상한(바이트). 붙여넣은 거대한 지시가 디스크와 프리뷰를 먹지 않게.
# awk 에 넘기기 전에 payload 를 자르는 상한(바이트).
#   ⚠ 이 줄이 없으면 훅이 통째로 멈춘다. mawk 의 문자 단위 누적은 O(n²)다 — 실측:
#     36KB=0.04s · 140KB=0.54s · 420KB=10.3s · 1.4MB=120s 초과. claude 훅 timeout 은 10s,
#     codex 는 5s 다. 붙여넣기 하나로 훅이 죽는다. 16KB 로 자르면 0.02s 다.
#   프롬프트는 payload 앞쪽 필드(session_id·cwd 등) 뒤에 오고 저장 상한이 4096 바이트라,
#   16KB 를 넘겨서 얻을 게 없다. 잘려서 값이 안 닫힌 채 끝나면 스캐너가 그걸 '잘림'으로
#   받아 적는다(아래 cut 플래그) — 조용히 포기하지 않는다.
TT_LASTP_SCAN=16384

# depth 1 의 prompt 키 하나만 뽑아 이스케이프를 풀고 제어문자를 걷어낸다.
#   rc 0 = 온전히 뽑음 / rc 2 = 뽑았지만 잘림 / rc 1 = 없음(아무것도 안 쓴다)
# 문자열 안/밖과 이스케이프 상태, 중괄호 깊이를 직접 추적하므로
#   · tool_input.prompt(depth 2) 에 안 속고
#   · 프롬프트 값 안에 사용자가 붙여넣은 {"prompt":"가짜"} 에도 안 속는다.
TT_LASTP_AWK='
    BEGIN { for (i = 1; i < 256; i++) ORD[sprintf("%c", i)] = i }
    { if (length(buf) < lim) buf = buf $0 "\n" }
    END {
        buf = substr(buf, 1, lim)
        n = length(buf); depth = 0; instr = 0; capture = 0; i = 1
        tok = ""; out = ""; found = 0; cut = 0
        while (i <= n) {
            c = substr(buf, i, 1)
            if (instr) {
                # 이스케이프는 두 글자를 통째로 넘긴다 — 여기서 풀면 \" 가 문자열 끝으로 보인다
                if (c == "\\") { tok = tok "\\" substr(buf, i + 1, 1); i += 2; continue }
                if (c == "\"") {
                    instr = 0
                    if (capture) { out = tok; found = 1; break }
                    last = tok; i++
                    # 방금 닫은 문자열이 키인지 값인지는 다음 비공백 문자가 : 인지로 안다
                    j = i; while (j <= n && substr(buf, j, 1) ~ /[ \t\n\r]/) j++
                    if (substr(buf, j, 1) == ":" && depth == 1 && last == "prompt") {
                        k = j + 1; while (k <= n && substr(buf, k, 1) ~ /[ \t\n\r]/) k++
                        if (substr(buf, k, 1) == "\"") { capture = 1; instr = 1; tok = ""; i = k + 1; continue }
                    }
                    continue
                }
                tok = tok c; i++; continue
            }
            if (c == "\"") { instr = 1; tok = ""; i++; continue }
            if (c == "{" || c == "[") { depth++; i++; continue }
            if (c == "}" || c == "]") { depth--; i++; continue }
            i++
        }
        # 입력 상한에 걸려 닫는 따옴표를 못 만난 채 끝났다 = 값의 끝을 EOF 로 받아들인다
        if (!found && capture && instr) { out = tok; found = 1; cut = 1 }
        if (!found) exit 1
        s = unesc(out)
        if (length(s) > maxb) { s = utf8trim(substr(s, 1, maxb)); cut = 1 }
        if (length(s) == 0) exit 1
        printf "%s", s
        if (cut) exit 2
    }
    # JSON 이스케이프 해제 + 제어문자 제거.
    #   개행·탭만 남긴다. 나머지 제어문자(특히 ESC)는 버린다 — 훅이 받는 건 사용자 입력이고,
    #   ESC 가 프리뷰로 흘러가면 커서 이동·화면 지움이 그대로 실행돼 관제탑이 깨진다.
    #   ⚠ C0 만 걸러선 모자란다. C1(U+0080–9F)에는 8비트 CSI(U+009B)가 있어 ESC 없이 혼자
    #     커서를 움직인다. UTF-8 로는 c2 80..c2 9f 두 바이트라 ORD[c] < 32 검사에 안 걸린다 —
    #     실측으로 `c2 9b` 가 저장 파일에 그대로 남았다. 두 바이트를 통째로 본다.
    # 코드포인트 → UTF-8 바이트열. LC_ALL=C 라 sprintf("%c", 큰수) 는 못 믿는다(구현마다 다르다) —
    #   바이트를 직접 조립한다. 이게 없으면 가 같은 이스케이프가 통째로 "?" 가 돼
    #   한글 프롬프트가 물음표 밭이 된다. claude·codex 는 한글을 raw UTF-8 로 보내므로
    #   이 경로를 안 타지만, 그건 관측이지 계약이 아니다.
    function utf8enc(v) {
        if (v < 128)   return sprintf("%c", v)
        if (v < 2048)  return sprintf("%c%c", 192 + int(v / 64), 128 + (v % 64))
        if (v < 65536) return sprintf("%c%c%c", 224 + int(v / 4096), 128 + int(v / 64) % 64, 128 + (v % 64))
        return sprintf("%c%c%c%c", 240 + int(v / 262144), 128 + int(v / 4096) % 64,
                       128 + int(v / 64) % 64, 128 + (v % 64))
    }
    function unesc(s,   r, p, m, c, e, lo, code) {
        r = ""; p = 1; m = length(s)
        while (p <= m) {
            c = substr(s, p, 1)
            if (c != "\\") {
                code = ORD[c]
                if (code == 127 || (code < 32 && c != "\n" && c != "\t")) { p++; continue }
                if (code == 194) {                             # C1 의 선행 바이트
                    e = ORD[substr(s, p + 1, 1)]
                    if (e >= 128 && e <= 159) { p += 2; continue }
                }
                r = r c; p++; continue
            }
            e = substr(s, p + 1, 1)
            if (e == "n")      { r = r "\n"; p += 2 }
            else if (e == "t") { r = r "\t"; p += 2 }
            else if (e == "r" || e == "b" || e == "f") { p += 2 }
            else if (e == "\"" || e == "\\" || e == "/") { r = r e; p += 2 }
            else if (e == "u") {
                code = hex4(substr(s, p + 2, 4)); p += 6
                # 서로게이트 쌍(😀 같은 이모지)은 둘을 합쳐야 한 글자다
                if (code >= 55296 && code <= 56319 && substr(s, p, 2) == "\\u") {
                    lo = hex4(substr(s, p + 2, 4))
                    if (lo >= 56320 && lo <= 57343) {
                        code = 65536 + (code - 55296) * 1024 + (lo - 56320); p += 6
                    }
                }
                if (code == 10) r = r "\n"
                else if (code == 9) r = r "\t"
                # 제어문자 — 버린다. C0+DEL(ESC 포함)과 C1(8비트 CSI 포함) 둘 다.
                else if (code < 32 || code == 127 || (code >= 128 && code <= 159)) { }
                else r = r utf8enc(code)
            }
            else if (e == "") { p += 2 }
            else { r = r e; p += 2 }
        }
        return r
    }
    function hex4(h,   d, v, q, ch) {
        d = "0123456789abcdef"; v = 0
        for (q = 1; q <= 4; q++) {
            ch = substr(h, q, 1)
            if (ch >= "A" && ch <= "F") ch = substr("abcdef", index("ABCDEF", ch), 1)
            v = v * 16 + (index(d, ch) - 1)
        }
        return v
    }
    # 바이트로 자른 끝에 남은 미완결 UTF-8 시퀀스를 떼낸다 — 안 떼면 프리뷰 끝에 깨진 글자가 선다
    function utf8trim(s,   L, q, c, need) {
        L = length(s)
        for (q = 0; q < 4 && L - q >= 1; q++) {
            c = ORD[substr(s, L - q, 1)]
            if (c < 128) return s                              # ASCII 로 끝났다 = 완결
            if (c >= 192) {                                    # 선행 바이트를 찾았다
                need = (c < 224) ? 2 : (c < 240 ? 3 : 4)
                if (q + 1 == need) return s                    # 딱 맞는다 = 완결
                return substr(s, 1, L - q - 1)                 # 모자란다 = 통째로 떼낸다
            }
        }
        return s
    }'

# 훅 경로에서 부른다. UserPromptSubmit 일 때만 실제로 일한다.
#   ⚠ bash 선(先)게이트가 핵심이다 — PostToolUse/PreToolUse/PreCompact 는 여기서 문자열
#     비교 하나로 되돌아가므로 포크가 하나도 안 는다(훅 경로 비용 유지). awk 포크는 사람이
#     프롬프트를 한 번 칠 때마다 한 번, 즉 툴콜 수와 무관하다.
#   게이트가 느슨해도(payload 어딘가에 그 문자열이 우연히 들어 있어도) 안전하다:
#     스캐너가 depth 1 의 prompt 만 보므로 다른 이벤트에서는 rc 1 로 조용히 끝난다.
#     예: 이 저장소를 편집하는 세션의 PostToolUse 는 tool_input 안에 이 소스 텍스트를
#     통째로 담고 오는데, 그건 문자열 값 안이라 깊이를 못 올린다.
tt_last_prompt_save() {
    local sid="$1" payload="$2" now="$3" body rc=0 id f t
    case "$payload" in
        *'"hook_event_name"'*'"UserPromptSubmit"'*) ;;
        *) return 0 ;;
    esac
    # herestring 은 문자열을 통째로 임시파일에 쓴다 — 3MB 붙여넣기를 그대로 넘기면 그 쓰기만으로
    #   0.4초가 든다. 여기서 먼저 줄인다. ${v:0:n} 은 UTF-8 로케일에서 **글자** 수라 항상
    #   n 바이트 이상이 남는다 → awk 의 바이트 상한(lim)이 볼 앞부분은 하나도 안 잘린다.
    body=$(LC_ALL=C awk -v lim="$TT_LASTP_SCAN" -v maxb="$TT_LASTP_MAX" \
            "$TT_LASTP_AWK" <<< "${payload:0:TT_LASTP_SCAN}" 2>/dev/null) || rc=$?
    case "$rc" in 0|2) ;; *) return 0 ;; esac
    [ -n "$body" ] || return 0
    id=${sid#\$}
    f="$STATE/last-$id"
    # tmp 이름은 점으로 시작한다 — last-* 글롭(sweep·프리뷰)에 안 걸리게.
    t="$STATE/.last-$id.$$"
    # 원자적 쓰기: 훅은 이벤트마다 도는 짧은 프로세스이고 프리뷰가 같은 파일을 동시에 읽는다.
    #   1행 = 기록 시각(+ 잘렸으면 trunc) / 2행~ = 본문
    # ── 0600 ───────────────────────────────────────────────────────────────
    # ⚠ 이 파일에는 **사용자가 친 프롬프트 원문**이 들어간다. ~/.cache/tt 에 대화 본문이
    #   놓이는 건 이번이 처음이다 — 같은 것을 담는 ~/.claude/projects 는 0700 이다.
    #   umask 에 맡기면 결과가 기계마다 갈린다: 022 면 -rw-r--r--, 002 면 -rw-rw-r-- 다.
    #   둘 다 **같은 기계의 다른 uid 가 읽는다**(이 파이만 해도 uid 1000·1001 둘이 있다).
    #   그래서 umask 를 여기서 직접 세운다 — 호출자 umask 가 무엇이든 결과가 같아야 한다.
    #   조이는 대상은 tmp 부터다: mv 전에도 그 자리에 이미 본문이 다 들어 있어 읽힌다.
    #   목적지는 따로 chmod 하지 않는다 — mv 는 rename 이라 tmp 의 모드를 그대로 옮기고,
    #   그래서 예전 판이 남긴 헐거운 last-<id> 도 다음 쓰기 한 번이면 0600 으로 갈린다.
    #   서브셸을 쓰는 이유: umask 를 되돌릴 필요가 없다. 이 경로는 사람이 프롬프트를 칠 때만
    #   도는 자리라(툴콜마다가 아니다) 포크 하나가 훅 비용 규율을 깨지 않는다.
    #   ⚠ umask 는 **새로 만드는** 파일에만 걸린다. `> "$t"` 는 그 이름이 이미 있으면 열어서
    #     자르기만 하고 모드는 예전 것을 그대로 둔다 — 그리고 mv 는 rename 이라 그 헐거운
    #     모드가 목적지까지 따라간다. 조각(.last-<id>.<pid>)은 훅이 mv 전에 죽으면 남고,
    #     pid 는 재사용되므로 "이미 있는 이름"은 실제로 일어난다. 서브셸에 들어가기 전에
    #     지워서 항상 새로 만든다.
    rm -f "$t" 2>/dev/null || true
    ( umask 077
      { if [ "$rc" = 2 ]; then echo "$now trunc"; else echo "$now"; fi
        printf '%s\n' "$body"; } > "$t" ) 2>/dev/null || { rm -f "$t" 2>/dev/null; return 0; }
    mv -f "$t" "$f" 2>/dev/null || rm -f "$t" 2>/dev/null
    return 0
}

# 프리뷰 헤더 렌더. 인자: cols(프리뷰 폭)·acc(accent 256색 번호). 입력: last-<sid> 파일.
#   출력 = 라벨 1줄 + 본문 최대 3줄 + 구분선 1줄 = 최대 5줄.
#   본문이 없거나 라벨 한 줄도 못 적을 만큼 좁으면 rc 1 로 아무것도 안 낸다.
#
#     last prompt ❯
#     module refactor 계속해줘.
#     Widget.change 로 접은 거 기준으로
#     … +4줄
#     ──────────────────────────────────────
#     ● Running 1 shell command…              ← 여기부터 화면 꼬리
#
#   ── 왜 이 모양인가 (사용자가 세 판 만에 고른 것) ───────────────────────────
#   ① **라벨은 제 줄을 갖는다.** `last prompt ❯` 는 셸 프롬프트처럼 읽힌다 — 그래서 다음
#      줄부터가 "사람이 친 글"이라는 걸 장식 없이 말한다. 구분감은 여기서 나온다.
#   ② **본문에는 접두를 안 붙인다.** 이전 판은 `❯ `/`  ` 두 칸을 앞에 뒀는데, 그 두 칸이
#      곧 두 칸만큼 더 잘린다는 뜻이다. 라벨을 위로 올리고 나면 접두가 할 일이 없다 —
#      본문은 창 폭을 통째로 쓴다.
#   ③ **박스·세로선·반전바는 폐기됐다.** 중간 판으로 다 만들어 봤고 "못생겼다"로 버려졌다.
#      다시 만들지 말 것. 덤으로: 박스는 우측 테두리를 맞추려고 매 줄을 패딩해야 해서
#      폭 계산이 한 칸만 틀려도 곧바로 들쭉날쭉해졌다. 지금은 폭 오차가 있어도 최악이
#      "한 글자 더/덜 잘림"이다.
#   ④ 색은 accent 를 따르되 라벨·구분선 **둘 다 dim** 이다. 읽어야 하는 건 본문이지
#      장식이 아니다 — 장식이 본문보다 밝으면 눈이 거기 먼저 간다.
#
#   ── 폭 계산이 필요한 이유 ──────────────────────────────────────────────────
#   접힘이 아니라 **누가 자르느냐**다. 90-main.sh 의 --preview-window 에는 wrap 이 없고
#   fzf 의 기본은 nowrap 이다. 그래서 폭을 넘는 줄은 접히지 않고(줄 수 회계는 안 깨진다)
#   fzf 가 **말없이** 잘라낸다. 프리뷰 맨 위 그 줄은 "내가 뭘 시켰더라"의 답이라, 뒤가 더
#   있다는 표시 없이 끊기면 남은 부분을 지시의 끝으로 읽는다. 그래서 우리가 먼저 잘라 …
#   를 붙인다. 한글은 한 글자가 두 칸이라 바이트로도 글자 수로도 못 잰다 → UTF-8 을 직접
#   해독한다(wcw 의 폭 표가 틀리면 우리가 붙인 … 가 먼저 잘려 나가 "잘렸다"는 표시조차
#   안 남는다 — 실측: `✅`×30 @cols=20 이 37칸으로 나갔다).
#
#   ⚠ 자르기 전에 sane() 으로 한 번 더 소독한다. 저장 쪽(unesc)이 이미 거르지만 렌더는
#     **파일을 믿지 않는다**: 손으로 만든 파일·옛 판이 남긴 파일·다른 uid 가 넣어 둔 파일이
#     그대로 들어온다. 헤더 한 줄이 깨지면 사용자 눈에는 팝업 전체가 망가진 것으로 보인다.
TT_LASTP_VIEW_AWK='
    BEGIN {
        for (i = 1; i < 256; i++) ORD[sprintf("%c", i)] = i
        E = sprintf("%c", 27); DIM = E "[2m"; RST = E "[0m"
        # 색은 설정의 accent 를 따른다 — 하드코딩하면 팀원이 색을 바꿔도 여기만 남는다.
        #   라벨·구분선 둘 다 dim 을 겹친다: 읽어야 하는 건 본문이지 장식이 아니다.
        if (acc !~ /^[0-9]+$/ || acc + 0 > 255) acc = "73"
        ACC = E "[2;38;5;" acc "m"
        LABEL = "last prompt ❯"                   # 셸 프롬프트처럼 읽히게 — 다음 줄부터가 내 글
        n = 0
    }
    NR == 1 { trunc = ($2 == "trunc"); next }
    { n++; body[n] = $0 }
    END {
        if (n == 0) exit 1
        cols = cols + 0
        # 못 그릴 바엔 없는 게 낫다 — 이 기능은 부가물이다. 헤더를 통째로 포기하면
        #   90-main.sh 가 예전 프리뷰(화면 꼬리)를 **바이트 그대로** 낸다.
        #   라벨 한 줄조차 못 적는 폭이면 헤더가 라벨을 자르며 시작한다 = 포기가 낫다.
        if (cols < width(LABEL)) exit 1
        # 줄 수 예산: 라벨 1 + 본문 최대 3 + 구분선 1 = 5. "… +N줄" 도 본문 한 줄을 먹으므로,
        #   더 있다는 표시가 필요하면 본문은 2줄까지만 보여준다.
        ell = (n > 3 || trunc)
        m = ell ? ((n > 2) ? 2 : n) : n
        rest = n - m
        print ACC LABEL RST
        # 본문에는 접두가 없다 — 창 폭을 통째로 쓴다. 접두 두 칸은 두 칸만큼 더 잘린다는 뜻이다.
        for (i = 1; i <= m; i++) print clip(sane(body[i]), cols)
        if (ell) {
            t = "…"
            if (rest > 0) t = t " +" rest "줄"
            if (trunc)    t = t " (잘림)"
            print DIM clip(t, cols) RST
        }
        print ACC rep("─", cols) RST
    }
    function rep(c, k,   s) { s = ""; while (k-- > 0) s = s c; return s }
    # 렌더 소독. clip 보다 **먼저** 돈다 — 폭을 세기 전에 폭이 정의되는 글자만 남겨야 한다.
    #   · 탭 → 공백 한 칸. 폭을 세는 대신 펴는 이유: 탭의 표시폭을 정하는 건 터미널의 탭
    #     스톱인데 프리뷰 창은 터미널 왼쪽 끝이 아니라 fzf 가 정한 자리에서 시작하므로
    #     (--preview-window right,65%) 스톱이 어디 서는지 우리는 알 수 없다. 폭 1 로
    #     세던 판을 실측했더니 20칸 한도에 58칸이 나갔다 — 헤더가 프리뷰 밖으로 밀렸다.
    #     펴 놓으면 우리가 센 폭과 터미널이 그리는 폭이 정의상 같아진다.
    #   · C0·DEL·C1(U+0080–9F)은 버린다. 한 줄 안에 개행은 애초에 없고(줄 단위 입력),
    #     ESC(C0)와 8비트 CSI(C1, U+009B)는 그대로 그리면 커서가 움직인다.
    #   · UTF-8 로 못 읽는 바이트도 버린다 — 홀로 선 연속 바이트(0x80–0xBF), 과잉 인코딩
    #     선행 바이트(0xC0·0xC1), 범위 밖(0xF5–0xFF), 그리고 뒤가 연속 바이트가 아닌
    #     선행 바이트. 폭이 정의되지 않는 깨진 조각이고, 0x9B 한 바이트는 8비트 터미널에서
    #     CSI 로 읽힌다. decode() 가 이런 바이트를 **한 바이트만** 먹고 돌려주므로 그 뒤
    #     글자는 그대로 산다(예전 판이 뒤 글자까지 삼키던 자리 — decode() 주석 참조).
    function sane(s,   L, p, v, o) {
        L = length(s); p = 1; o = ""
        while (p <= L) {
            v = decode(s, p)
            if (v == 65533 && CPLEN == 1) { p++; continue }        # 깨진 UTF-8 조각
            if (v == 9) o = o " "
            else if (v < 32 || v == 127 || (v >= 128 && v <= 159)) { }
            else o = o substr(s, p, CPLEN)
            p += CPLEN
        }
        return o
    }
    function width(s,   L, p, t) {
        L = length(s); p = 1; t = 0
        while (p <= L) { t += wcw(decode(s, p)); p += CPLEN }
        return t
    }
    function clip(s, w,   L, p, cw, used, o) {
        if (width(s) <= w) return s
        L = length(s); p = 1; used = 0; o = ""
        while (p <= L) {
            cw = wcw(decode(s, p))
            if (used + cw > w - 1) break          # 마지막 한 칸은 … 자리로 남긴다
            o = o substr(s, p, CPLEN); used += cw; p += CPLEN
        }
        return o "…"
    }
    # UTF-8 한 글자를 코드포인트로. 소비한 바이트 수는 전역 CPLEN 으로 돌려준다.
    #   읽을 수 없는 바이트는 **한 바이트만** 먹고 65533 을 돌려준다 — 그래야 sane() 이 그
    #   한 바이트만 버리고 뒤 글자를 그대로 살린다.
    #   ⚠ 예전 판은 0xC0·0xC1·0xF5–0xFF 를 정상 선행 바이트로 받았고, 다바이트 분기에서
    #     뒤따르는 바이트가 연속 바이트(0x80–0xBF)인지도 확인하지 않았다. 실측 두 가지:
    #       · `0xC2` + "ABCDE" → v = 2*64 + (65 % 64) = 129 로 C1 그물(128–159)에 걸리고
    #         CPLEN=2 라 **사용자가 친 A 가 소리 없이 사라졌다**.
    #       · `0xC0` + "X"     → v = 0*64 + (88 % 64) = 24 로 C0 취급돼 X 까지 데려갔다.
    function decode(s, p,   c, need, v, q, b) {
        c = ORD[substr(s, p, 1)]
        if (c < 128) { CPLEN = 1; return c }
        # 선행 바이트가 될 수 없는 값: 홀로 선 연속 바이트(128–191)·과잉 인코딩(192·193)·
        #   범위 밖(245–255). 전부 한 바이트만 먹는다.
        if (c < 194 || c > 244) { CPLEN = 1; return 65533 }
        if (c >= 240) { need = 4; v = c - 240 }
        else if (c >= 224) { need = 3; v = c - 224 }
        else { need = 2; v = c - 192 }
        for (q = 1; q < need; q++) {
            b = ORD[substr(s, p + q, 1)]
            # 문자열 끝을 넘어가면 ORD[""] 가 미정의 = 0 이라 여기 걸린다(잘린 시퀀스).
            if (b < 128 || b > 191) { CPLEN = 1; return 65533 }
            v = v * 64 + (b % 64)
        }
        CPLEN = need
        return v
    }
    # 동아시아 넓은 글자는 두 칸. 16진 리터럴은 안 쓴다(mawk·BSD awk 호환).
    #   EastAsianWidth 의 W/F 만 담는다. A(Ambiguous)는 1칸으로 둔다 — 터미널 기본값이다.
    #   ⚠ BMP 의 기호·이모지 구간이 통째로 빠져 있었다(실측: `✅`×30 @cols=20 → 37칸).
    #     `if (v >= 127744 …)` 한 줄로는 U+1F300 이상만 잡힌다 — ✅(U+2705)·❌(U+274C)·
    #     ⭐(U+2B50)·⛔(U+26D4) 처럼 자주 쓰는 것들은 죄다 그 아래에 산다.
    #     이 오차는 그냥 "줄이 좀 길어지는" 문제가 아니다: 우리가 붙인 … 자체가 폭 밖으로
    #     밀려 fzf 에게 잘려 나가므로 **잘렸다는 표시조차 안 남는다**.
    function wcw(v) {
        if (v < 4352)                   return 1      # ASCII·라틴·기호 대부분은 여기서 끝
        if (v <= 4447)                  return 2      # 한글 자모
        if (v >= 8986   && v <= 8987)   return 2      # ⌚⌛
        if (v == 9001   || v == 9002)   return 2      # 〈 〉
        if (v >= 9193   && v <= 9196)   return 2      # ⏩⏪⏫⏬
        if (v == 9200   || v == 9203)   return 2      # ⏰ ⏳
        if (v >= 9725   && v <= 9726)   return 2      # ◽◾
        if (v >= 9748   && v <= 9749)   return 2      # ☔☕
        if (v >= 9800   && v <= 9811)   return 2      # ♈–♓ 별자리
        if (v == 9855)                  return 2      # ♿
        if (v == 9875)                  return 2      # ⚓
        if (v == 9889)                  return 2      # ⚡
        if (v >= 9898   && v <= 9899)   return 2      # ⚪⚫
        if (v >= 9917   && v <= 9918)   return 2      # ⚽⚾
        if (v >= 9924   && v <= 9925)   return 2      # ⛄⛅
        if (v == 9934)                  return 2      # ⛎
        if (v == 9940)                  return 2      # ⛔
        if (v == 9962)                  return 2      # ⛪
        if (v >= 9970   && v <= 9971)   return 2      # ⛲⛳
        if (v == 9973)                  return 2      # ⛵
        if (v == 9978)                  return 2      # ⛺
        if (v == 9981)                  return 2      # ⛽
        if (v == 9989)                  return 2      # ✅
        if (v >= 9994   && v <= 9995)   return 2      # ✊✋
        if (v == 10024)                 return 2      # ✨
        if (v == 10060)                 return 2      # ❌
        if (v == 10062)                 return 2      # ❎
        if (v >= 10067  && v <= 10069)  return 2      # ❓❔❕
        if (v == 10071)                 return 2      # ❗
        if (v >= 10133  && v <= 10135)  return 2      # ➕➖➗
        if (v == 10160)                 return 2      # ➰
        if (v == 10175)                 return 2      # ➿
        if (v >= 11035  && v <= 11036)  return 2      # ⬛⬜
        if (v == 11088)                 return 2      # ⭐
        if (v == 11093)                 return 2      # ⭕
        if (v >= 11904  && v <= 42191)  return 2      # CJK 부수 ~ Yi
        if (v >= 43360  && v <= 43388)  return 2      # 한글 자모 확장-A
        if (v >= 44032  && v <= 55203)  return 2      # 한글 음절
        if (v >= 63744  && v <= 64255)  return 2      # CJK 호환 한자
        if (v >= 65072  && v <= 65135)  return 2      # CJK 호환 형태
        if (v >= 65280  && v <= 65376)  return 2      # 전각 영숫자
        if (v >= 65504  && v <= 65510)  return 2
        if (v >= 127744 && v <= 129791) return 2      # 이모지
        if (v >= 131072 && v <= 262141) return 2      # SIP
        return 1
    }'

