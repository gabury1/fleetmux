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
                else if (code < 32 || code == 127) { }         # 제어문자 — 버린다(ESC 포함)
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
    { if [ "$rc" = 2 ]; then echo "$now trunc"; else echo "$now"; fi
      printf '%s\n' "$body"; } > "$t" 2>/dev/null || { rm -f "$t" 2>/dev/null; return 0; }
    mv -f "$t" "$f" 2>/dev/null || rm -f "$t" 2>/dev/null
    return 0
}

# 프리뷰 헤더 렌더. 인자: cols(프리뷰 폭). 입력: last-<sid> 파일.
#   출력 = 헤더 줄들(최대 3줄 + "… +N줄" + 구분선). 본문이 없으면 rc 1 로 아무것도 안 낸다.
#   폭 계산이 필요한 이유: 줄이 프리뷰 폭을 넘으면 fzf 가 접어서 두 줄로 그린다 —
#   그러면 호출부가 뺀 줄 수가 틀려 프리뷰 위가 잘린다. 한글은 한 글자가 두 칸이라
#   바이트로도 글자 수로도 못 잰다. 그래서 UTF-8 을 직접 해독해 표시 폭으로 자른다.
TT_LASTP_VIEW_AWK='
    BEGIN {
        for (i = 1; i < 256; i++) ORD[sprintf("%c", i)] = i
        E = sprintf("%c", 27); DIM = E "[2m"; RST = E "[0m"
        n = 0
    }
    NR == 1 { trunc = ($2 == "trunc"); next }
    { n++; body[n] = $0 }
    END {
        if (n == 0) exit 1
        w = cols - 2; if (w < 8) w = 8            # 앞머리 "❯ " / "  " 두 칸을 뺀다
        m = (n > 3) ? 3 : n
        for (i = 1; i <= m; i++) printf "%s%s\n", (i == 1 ? "❯ " : "  "), clip(body[i], w)
        rest = n - m
        if (rest > 0 || trunc) {
            t = "  …"
            if (rest > 0) t = t " +" rest "줄"
            if (trunc)    t = t " (잘림)"
            print DIM t RST
        }
        bar = ""; for (i = 0; i < cols; i++) bar = bar "─"
        print DIM bar RST
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
    function decode(s, p,   c, need, v, q) {
        c = ORD[substr(s, p, 1)]
        if (c < 128) { CPLEN = 1; return c }
        if (c >= 240) { need = 4; v = c - 240 }
        else if (c >= 224) { need = 3; v = c - 224 }
        else if (c >= 192) { need = 2; v = c - 192 }
        else { CPLEN = 1; return 65533 }          # 홀로 선 연속 바이트 — 폭 1 로 센다
        for (q = 1; q < need; q++) v = v * 64 + (ORD[substr(s, p + q, 1)] % 64)
        CPLEN = need
        return v
    }
    # 동아시아 넓은 글자는 두 칸. 16진 리터럴은 안 쓴다(mawk·BSD awk 호환).
    function wcw(v) {
        if (v >= 4352   && v <= 4447)   return 2      # 한글 자모
        if (v == 8985   || v == 8986)   return 2      # 〈 〉
        if (v >= 11904  && v <= 42191)  return 2      # CJK 부수 ~ Yi
        if (v >= 44032  && v <= 55203)  return 2      # 한글 음절
        if (v >= 63744  && v <= 64255)  return 2      # CJK 호환 한자
        if (v >= 65072  && v <= 65135)  return 2      # CJK 호환 형태
        if (v >= 65280  && v <= 65376)  return 2      # 전각 영숫자
        if (v >= 65504  && v <= 65510)  return 2
        if (v >= 127744 && v <= 129791) return 2      # 이모지
        if (v >= 131072 && v <= 262141) return 2      # SIP
        return 1
    }'

