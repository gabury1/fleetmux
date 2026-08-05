#!/usr/bin/env bash
# fleetmux 설치기 — 팀원이 자기 기계에 fmux 를 올릴 때 한 번 돌린다.
#
#   ./install.sh              물어보면서 설치
#   ./install.sh --dry-run    아무것도 안 바꾸고 할 일만 출력
#   ./install.sh --yes        물음에 전부 yes (제안된 기본값을 그대로 받는다)
#                             소환키만은 예외 — safe(아무 키도 안 뺏음)로 간다. 무prefix 키를
#                             전역으로 뺏는 것은 --preset 으로 명시할 때만 일어난다.
#                             (물어볼 수 있을 때의 제안은 shift = S-Left 다. 왜 그 키인지는
#                              아래 "⑤ 소환키 프리셋" 절 머리말에 근거를 적어 뒀다.)
#   curl -fsSL <URL> | bash   레포 없이 설치(원격 모드) — 릴리스 아카이브를 받아 깐다
#
# 모드가 둘이다. 어느 쪽인지는 **파일 존재로** 가르고, 화면 머리에 한 줄로 밝힌다:
#   로컬 — 이 스크립트 옆에 레포가 있다(Makefile·src/·bin/fmux 가 보인다). 그것을 깐다.
#   원격 — 없다(`curl | bash` 로 들어왔다). 릴리스 아카이브를 받아 임시 디렉토리에 풀고
#          그것을 레포처럼 써서 아래 여덟 단계를 똑같이 밟는다. 끝나거나 실패하면 지운다.
#
# 규율 넷 — 이 파일을 고칠 사람에게:
#   ① 멱등하다. 두 번 돌려도 안전하고, 이미 있는 것은 덮기 전에 알린다.
#   ② --dry-run 은 파일을 하나도 안 만든다. 새 단계를 넣을 때 이 갈림을 빠뜨리지 마라.
#      (원격 모드의 --dry-run 은 아카이브를 받기는 받는다 — 받아 봐야 무엇을 깔지 말할 수
#       있기 때문이다. 다만 **임시 디렉토리 밖으로는 한 바이트도 안 나가고**, 끝나면 지운다.)
#   ③ 남의 파일은 동의 없이 안 고친다. ~/.tmux.conf 는 물어보고 한 줄만,
#      crontab 은 아예 안 고친다 — 보여주기만 한다(이 프로젝트의 원칙).
#   ④ 실패하면 어디까지 했는지 말하고 멈춘다. 조용한 반쪽 설치를 만들지 않는다.
#
# 이식성: bash 3.2 호환(연관배열·${v^^}·소수점 read -t 금지), GNU 전용 옵션 금지
#   (stat -c·readlink -f·sed -i·sort -V 금지). macOS 와 리눅스 양쪽에서 돌아야 한다.
# 색·이모지는 쓰지 않는다 — 팀원 터미널이 무엇일지 모른다.

set -u

REPO=$(cd "$(dirname "$0")" 2>/dev/null && pwd -P) || { echo "install.sh 가 있는 디렉토리를 못 찾았다" >&2; exit 1; }

PREFIX="${PREFIX:-$HOME/.local}"
DRY=0
ASSUME_YES=0
PRESET=""
REF=""

usage() {
    cat << 'EOF'
usage: ./install.sh [옵션]
       curl -fsSL <URL> | bash              (원격 모드 — 레포 없이)
       curl -fsSL <URL> | bash -s -- --ref v1.2.3

  -n, --dry-run       아무것도 바꾸지 않고 할 일만 출력한다
  -y, --yes           물음에 전부 yes (제안된 기본값을 그대로 받는다)
                      단, 소환키는 safe 로 간다 — 무prefix 키는 아무것도 안 뺏는다
      --prefix DIR    설치 위치 (기본 ~/.local — bin/ 과 libexec/tt/ 가 그 밑에 생긴다)
      --preset NAME   소환키 프리셋: shift | safe | mac | linux | wsl
                      물어볼 수 있으면 shift(S-Left)를 제안한다 — 맥·리눅스·Windows Terminal
                      세 곳 모두에 도착하는 유일한 무prefix 한 타건이다. 대신 그 pane 안
                      모든 앱에서 그 키를 가져간다. --yes 로는 안 뺏는다 — 무prefix 키를
                      뺏는 것은 여기서 명시할 때만 일어난다.
      --ref TAG       원격 모드에서 받을 태그(또는 브랜치). 기본은 **최신 릴리스 태그**다.
                      로컬 모드에서는 쓰이지 않는다.
  -h, --help          이 도움말

무엇을 하나: (원격이면 릴리스 아카이브 받기 →) 의존성 확인 → 바이너리 설치 →
훅 shim 배치 → tmux 스니펫 → 소환키 프리셋 → 에이전트 스킬 → 크론 안내 → 요약.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -n|--dry-run) DRY=1 ;;
        -y|--yes)     ASSUME_YES=1 ;;
        --prefix)     [ $# -ge 2 ] || { echo "--prefix 에 디렉토리가 없다" >&2; exit 2; }; PREFIX="$2"; shift ;;
        --prefix=*)   PREFIX="${1#--prefix=}" ;;
        --preset)     [ $# -ge 2 ] || { echo "--preset 에 이름이 없다" >&2; exit 2; }; PRESET="$2"; shift ;;
        --preset=*)   PRESET="${1#--preset=}" ;;
        --ref)        [ $# -ge 2 ] || { echo "--ref 에 태그가 없다" >&2; exit 2; }; REF="$2"; shift ;;
        --ref=*)      REF="${1#--ref=}" ;;
        -h|--help)    usage; exit 0 ;;
        *) echo "모르는 옵션: $1" >&2; echo >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# 상대경로 PREFIX 는 절대경로로 편다. `make -C "$REPO" install PREFIX=./x` 는 레포 기준으로
# 풀려서, 사람이 친 자리가 아닌 곳에 깔린다 — 그 놀람을 여기서 없앤다.
case "$PREFIX" in
    /*) ;;
    *)  PREFIX="$PWD/$PREFIX" ;;
esac

BINDIR="$PREFIX/bin"
LIBEXEC="$PREFIX/libexec/tt"     # PATH shim 자리. README·70-fleet.sh 의 PATH 보정과 같은 경로여야 한다.

# ── 출력 ────────────────────────────────────────────────────────────────────
# 태그는 전부 4칸 ASCII 다. 한글 태그는 터미널마다 폭이 달라 표가 어긋난다.
step() { printf '\n[%s] %s\n' "$1" "$2"; }
ok()   { printf '  ok   %s\n' "$*"; }
note() { printf '  note %s\n' "$*"; }
skip() { printf '  skip %s\n' "$*"; }
plan() { printf '  dry  %s\n' "$*"; }        # --dry-run 에서 "이걸 했을 것이다"
warn() { printf '  warn %s\n' "$*" >&2; }

# 한 일 목록 — 실패해도 여기까지는 말한다(규율 ④).
DID=''
did() { DID="$DID  - $1"$'\n'; }

die() {
    printf '\n설치를 멈춘다: %s\n' "$1" >&2
    if [ -n "$DID" ]; then
        printf '\n여기까지 했다 — 나머지는 안 했다:\n%s' "$DID" >&2
        printf '되돌리려면 위 목록을 지우면 된다.\n' >&2
    else
        printf '\n아무것도 바꾸지 않았다.\n' >&2
    fi
    exit 1
}

is_dry() { [ "$DRY" = 1 ]; }

# ── 물어보기 ────────────────────────────────────────────────────────────────
# stdin 이 터미널이 아니면(파이프·CI·테스트) 절대 묻지 않고 "아니오"로 간다.
# 동의가 필요한 일은 동의가 없으면 안 한다 — 침묵은 동의가 아니다.
ASK_TTY=0
[ -t 0 ] && ASK_TTY=1

ask_yn() {   # $1=질문  → rc 0 이면 yes
    local q="$1" ans=''
    if [ "$ASSUME_YES" = 1 ]; then
        printf '  %s [y/n] y  (--yes)\n' "$q"
        return 0
    fi
    if [ "$ASK_TTY" = 0 ]; then
        printf '  %s [y/n] n  (터미널이 아니라 묻지 않았다 — 동의 없이는 안 한다)\n' "$q"
        return 1
    fi
    printf '  %s [y/N] ' "$q"
    read -r ans || ans=''
    case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

ask_word() {   # $1=질문  $2=기본값  → 답을 stdout 에
    local q="$1" def="$2" ans=''
    if [ "$ASSUME_YES" = 1 ] || [ "$ASK_TTY" = 0 ]; then printf '%s' "$def"; return 0; fi
    printf '  %s [%s] ' "$q" "$def" >&2
    read -r ans || ans=''
    [ -n "$ans" ] || ans="$def"
    printf '%s' "$ans"
}

# ── 버전 비교 ───────────────────────────────────────────────────────────────
# GNU `sort -V` 에 기대지 않는다 — macOS 의 BSD sort 에는 없다.
# 앞쪽의 숫자.점 부분만 떼어 성분끼리 센다: "3.5a"→3.5, "0.65.2 (brew)"→0.65.2,
# "5.2.37(1)-release"→5.2.37. 앞이 숫자가 아니면("next-3.6", "master") 빈 값 = 판독 실패.
ver_num() {
    local v="${1:-}"
    v=${v%%[!0-9.]*}
    while [ -n "$v" ] && [ "${v%.}" != "$v" ]; do v=${v%.}; done
    printf '%s' "$v"
}

# rc 0 = $1 >= $2, rc 1 = 낮다, rc 2 = 판독 실패(모르면 막지 않는다)
ver_ge() {
    local a b ai bi
    a=$(ver_num "${1:-}"); b=$(ver_num "${2:-}")
    [ -n "$a" ] || return 2
    [ -n "$b" ] || return 2
    while [ -n "$a" ] || [ -n "$b" ]; do
        ai=${a%%.*}; bi=${b%%.*}
        case "$a" in *.*) a=${a#*.} ;; *) a='' ;; esac
        case "$b" in *.*) b=${b#*.} ;; *) b='' ;; esac
        # 앞자리 0 은 bash 산술에서 8진수다 → 10# 으로 정규화(05-config.sh 의 tt_conf_num 과 같은 이유)
        case "$ai" in ''|*[!0-9]*) ai=0 ;; *) ai=$((10#$ai)) ;; esac
        case "$bi" in ''|*[!0-9]*) bi=0 ;; *) bi=$((10#$bi)) ;; esac
        [ "$ai" -gt "$bi" ] && return 0
        [ "$ai" -lt "$bi" ] && return 1
    done
    return 0
}

# ── PATH 훑기 ───────────────────────────────────────────────────────────────
# `for d in $PATH` 는 IFS 를 갈아야 해서 함수 밖으로 새기 쉽다. 파라미터 확장으로 자른다.
# 빈 성분은 POSIX 상 현재 디렉토리(.)를 뜻한다.
path_index() {   # $1=디렉토리 → PATH 에서 몇 번째인가(1부터). 없으면 0.
    local want="${1:-}" rest="$PATH:" d i=0
    want=${want%/}
    while [ -n "$rest" ]; do
        d=${rest%%:*}; rest=${rest#*:}
        i=$((i + 1))
        [ -n "$d" ] || d=.
        [ "${d%/}" = "$want" ] && { printf '%s' "$i"; return 0; }
    done
    printf '0'
}

first_real_index() {   # $1=명령 이름 → LIBEXEC 를 뺀 PATH 에서 처음 나오는 순번. 없으면 0.
    local want="${1:-}" rest="$PATH:" d i=0
    while [ -n "$rest" ]; do
        d=${rest%%:*}; rest=${rest#*:}
        i=$((i + 1))
        [ -n "$d" ] || d=.
        [ "${d%/}" = "${LIBEXEC%/}" ] && continue
        [ -x "$d/$want" ] && { printf '%s' "$i"; return 0; }
    done
    printf '0'
}

rc_hint() {   # 셸 시작 파일 이름 추정 — 고치지는 않는다. 어디를 열지만 알려준다.
    case "$(basename "${SHELL:-sh}")" in
        zsh)  printf '~/.zshrc' ;;
        bash) if [ "$(uname -s)" = Darwin ]; then printf '~/.bash_profile'; else printf '~/.bashrc'; fi ;;
        fish) printf '~/.config/fish/config.fish' ;;
        *)    printf '셸 시작 파일' ;;
    esac
}

path_line() {   # PATH 를 넣는 한 줄 — fish 는 문법이 다르다
    if [ "$(basename "${SHELL:-sh}")" = fish ]; then
        printf 'fish_add_path %s %s' "$LIBEXEC" "$BINDIR"
    else
        printf 'export PATH="%s:%s:$PATH"' "$LIBEXEC" "$BINDIR"
    fi
}

# 설치된 fmux 가 있으면 그걸, 아직 없으면(dry-run) 레포의 것을 쓴다.
FMUX="$REPO/bin/fmux"

# ── tt 라는 이름 ────────────────────────────────────────────────────────────
# shim(libexec/claude)이 `command -v tt` 로 우리 존재를 확인하므로 이 이름이 필요하다.
# 그런데 ~/.local/bin 에 개인 도구를 거는 가장 흔한 방식이 **심링크**다 — 팀원이 이미
# 다른 도구를 tt 로 쓰고 있을 수 있다. 예전 가드는 `[ -e ] && [ ! -L ]` 이라 일반 파일만
# 지키고 남의 심링크는 경고도 백업도 없이 갈아쳤다(팀 배포 게이트 I2). 원래 대상이 어디에도
# 안 남으므로 되돌릴 수 없고, 화면은 `ok …/tt → fmux` 만 찍었다.
# 규칙: **비어 있거나 우리 것일 때만** 건다. 그 밖이면 무엇이 있는지 보여주고 사람이 정한다.
tt_link_absent() {   # rc 0 = 그 자리가 비어 있다(끊어진 심링크는 비어 있는 게 아니다)
    [ ! -e "$BINDIR/tt" ] && [ ! -L "$BINDIR/tt" ]
}

tt_link_ours() {     # rc 0 = 우리가 건 심링크다 (재실행이 멱등해야 하므로 다시 걸어도 된다)
    local t
    [ -L "$BINDIR/tt" ] || return 1
    t=$(readlink "$BINDIR/tt" 2>/dev/null) || return 1
    [ "$t" = fmux ] || [ "$t" = "$BINDIR/fmux" ]
}

tt_link_what() {     # 그 자리에 무엇이 있나 — 사람이 정하려면 이것부터 봐야 한다
    if [ -L "$BINDIR/tt" ]; then
        printf '심링크 → %s' "$(readlink "$BINDIR/tt" 2>/dev/null || printf '?')"
    elif [ -d "$BINDIR/tt" ]; then printf '디렉토리'
    elif [ -e "$BINDIR/tt" ]; then printf '일반 파일'
    else printf '없음'
    fi
}

# ── 원격 모드 ───────────────────────────────────────────────────────────────
# `curl -fsSL … | bash` 로 들어오면 $0 은 'bash' 이고 dirname 은 '.' 이라, 위에서 잡은 REPO 는
# 그냥 "지금 디렉토리"다. 거기 우리 파일이 있을 리 없다 — 그래서 **파일 존재로** 가른다.
# (거꾸로, 클론 안에서 파이프로 돌려도 파일이 보이므로 로컬로 간다. 그게 맞다.)
REMOTE=0
[ -f "$REPO/bin/fmux" ] && [ -d "$REPO/src" ] && [ -f "$REPO/Makefile" ] || REMOTE=1

# 공개 배포 주소. **레포가 아직 비공개라 여기는 자리표시자다.**
#   공개되면 고칠 곳은 둘뿐이다: 이 기본값과 README 의 Install 절 URL.
# 포크·사설 미러·시험은 FMUX_SLUG 로 덮어쓴다 (FMUX_SLUG=owner/repo ./install.sh).
SLUG="${FMUX_SLUG:-OWNER/fleetmux}"
SLUG_IS_PLACEHOLDER=0
[ "$SLUG" = 'OWNER/fleetmux' ] && SLUG_IS_PLACEHOLDER=1

DL=''        # 받는 도구: curl | wget
SHA_CMD=''   # 대조 도구: sha256sum(리눅스) | shasum -a 256(맥). 없으면 빈 값.
TMPD=''      # 원격 모드의 임시 디렉토리. 성공하든 실패하든 EXIT 에서 지운다.

# 지우는 것은 trap 하나에만 맡긴다 — 성공 경로에서만 지우는 코드는 언젠가 실패 경로를 샌다.
# die() 도 exit 로 나가므로 이 trap 을 지난다.
cleanup_tmpd() {
    [ -n "$TMPD" ] || return 0
    if [ -d "$TMPD" ]; then
        rm -rf "$TMPD" && printf '  ok   임시 디렉토리를 지웠다: %s\n' "$TMPD"
    fi
    TMPD=''
}
trap 'cleanup_tmpd' EXIT
trap 'cleanup_tmpd; exit 130' INT
trap 'cleanup_tmpd; exit 143' TERM

# curl 우선, 없으면 wget. 둘 다 없으면 무엇을 깔지 말하고 멈춘다.
pick_downloader() {
    if command -v curl > /dev/null 2>&1; then DL=curl; ok "curl 로 받는다"
    elif command -v wget > /dev/null 2>&1; then DL=wget; ok "wget 으로 받는다 (curl 이 없다)"
    else
        warn "curl 도 wget 도 없다 — 아무것도 받을 수 없다."
        warn "     둘 중 하나를 깔아라:  apt install curl  /  dnf install curl  /  brew install curl"
        warn "     또는 레포를 클론해서 그 안에서 ./install.sh 를 돌려라(로컬 모드)."
        die "받을 도구가 없다"
    fi
}

# $1=URL $2=받을 파일. rc 0 이면 받았다. 404·네트워크 실패는 rc≠0 이고 빈 파일을 안 남긴다
# (wget -O 는 실패해도 파일을 만든다 — 그 껍데기를 다음 단계가 "받았다"고 믿으면 안 된다).
fetch() {
    local rc=0
    case "$DL" in
        curl) curl -fsSL --max-time 60 -o "$2" "$1" || rc=$? ;;
        wget) wget -q -T 60 -O "$2" "$1" || rc=$? ;;
        *)    rc=1 ;;
    esac
    if [ "$rc" != 0 ] || [ ! -s "$2" ]; then rm -f "$2"; return 1; fi
    return 0
}

# 최신 릴리스 태그. 못 알아내면 rc 1 — **main 으로 흘러가지 않는다.**
# main 이 깨진 순간 신규 설치가 전부 같이 깨지는 것이 태그를 기본으로 두는 이유다.
# 파서는 sed 하나다(jq 는 없는 기계가 많다). 쉼표로 줄을 갈라 "tag_name":"…" 를 뽑는다.
latest_tag() {
    local f="$TMPD/latest.json" t=''
    fetch "https://api.github.com/repos/$SLUG/releases/latest" "$f" || return 1
    t=$(tr ',' '\n' < "$f" \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -1)
    [ -n "$t" ] || return 1
    printf '%s' "$t"
}

pick_sha() {
    if command -v sha256sum > /dev/null 2>&1; then SHA_CMD='sha256sum'
    elif command -v shasum > /dev/null 2>&1; then SHA_CMD='shasum -a 256'
    else SHA_CMD=''
    fi
}

# 대조를 못 하는 상황. 파이프 설치의 방어선은 이 대조 하나뿐이라 **조용히 넘어가지 않는다**.
#   - --yes: 멈춘다. 자동 실행이 무검증으로 깔리면 안 된다.
#   - 물을 수 있으면: 묻는다. 사람이 눈으로 보고 승낙할 때만 계속한다.
#   - 물을 수 없으면(파이프 설치는 stdin 이 스크립트라 늘 여기다): ask_yn 이 '아니오'다 → 멈춘다.
no_verify_gate() {   # $1=왜 대조를 못 하나
    warn "$1"
    warn "     SHA256 대조는 파이프 설치(curl | bash)의 유일한 방어선이다 — 무검증으로 깔지 않는다."
    if [ "$ASSUME_YES" = 1 ]; then
        die "--yes 로는 무검증 설치를 승인하지 않는다 (사람이 직접 답할 때만 계속한다)"
    fi
    ask_yn "SHA256 대조 없이 그래도 계속할까?" || die "검증 없이는 설치하지 않는다"
    note "사람이 무검증 설치를 승낙했다 — 계속한다"
}

# SHA256SUMS 대조. 어긋나면 **즉시** 멈춘다(경고하고 계속하는 선택지는 없다).
verify_sums() {   # $1=받은 아카이브  $2=SHA256SUMS
    local name want got
    name=$(basename "$1")
    pick_sha
    if [ -z "$SHA_CMD" ]; then
        no_verify_gate "sha256sum 도 shasum 도 없다 — 받은 파일을 대조할 도구가 이 기계에 없다."
        return 0
    fi
    # 형식: '<해시>  <파일이름>' (바이너리 표시 '*' 가 붙기도 한다)
    want=$(awk -v f="$name" '{ n=$2; sub(/^\*/, "", n); if (n == f) { print $1; exit } }' "$2")
    [ -n "$want" ] || die "SHA256SUMS 에 $name 항목이 없다 — 이 아카이브는 대조할 수 없다"
    got=$($SHA_CMD "$1" 2>/dev/null | awk 'NR==1{print $1}')
    [ -n "$got" ] || die "$SHA_CMD 가 해시를 못 냈다 — 대조할 수 없다"
    if [ "$want" = "$got" ]; then
        ok "SHA256 일치 — $name"
        return 0
    fi
    warn "기대: $want"
    warn "실제: $got"
    die "SHA256 가 다르다 — 받은 파일이 릴리스와 같지 않다. 설치하지 않는다."
}

# ── 0단계: 원격이면 여기서 받는다 (여덟 단계 앞에 붙는다) ───────────────────
remote_fetch() {
    step 0/8 "원격 — 릴리스 아카이브를 받는다"
    local asset root d

    pick_downloader
    command -v tar > /dev/null 2>&1 || die "tar 가 없다 — 아카이브를 풀 수 없다"

    if [ "$SLUG_IS_PLACEHOLDER" = 1 ]; then
        warn "이 빌드에는 아직 공개 배포 주소가 없다 — 레포가 비공개라 자리표시자($SLUG)로 둔 상태다."
        warn "     공개되면 고칠 곳은 둘이다: install.sh 의 SLUG 기본값, README 의 Install 절 URL."
        warn "     지금 당장 원격으로 깔려면 주소를 직접 줘라:  FMUX_SLUG=owner/repo bash install.sh"
        warn "     또는 레포를 클론해서 그 안에서 ./install.sh 를 돌려라(로컬 모드)."
        die "받을 곳을 모른다"
    fi

    TMPD=$(mktemp -d "${TMPDIR:-/tmp}/fmux-install.XXXXXX") || die "임시 디렉토리를 못 만들었다"
    ok "임시 디렉토리: $TMPD  (끝나거나 실패하면 지운다)"

    if [ -n "$REF" ]; then
        note "--ref 로 받는다: $REF"
    else
        REF=$(latest_tag) || REF=''
        if [ -z "$REF" ]; then
            warn "최신 릴리스 태그를 알아내지 못했다 (https://api.github.com/repos/$SLUG/releases/latest)."
            warn "     main 으로 대신 받지 않는다 — main 이 깨진 날 신규 설치가 전부 같이 깨진다."
            warn "     받을 것을 직접 지정해라:  ... | bash -s -- --ref v1.2.3"
            die "무엇을 받을지 정하지 못했다"
        fi
        ok "최신 릴리스 태그: $REF"
    fi

    asset="fleetmux-$REF.tar.gz"
    if fetch "https://github.com/$SLUG/releases/download/$REF/$asset" "$TMPD/$asset"; then
        ok "받았다: $asset"
        if fetch "https://github.com/$SLUG/releases/download/$REF/SHA256SUMS" "$TMPD/SHA256SUMS"; then
            verify_sums "$TMPD/$asset" "$TMPD/SHA256SUMS"
        else
            no_verify_gate "이 릴리스($REF)에 SHA256SUMS 가 없다 — 받은 파일을 대조할 기준이 없다."
        fi
    elif fetch "https://github.com/$SLUG/archive/$REF.tar.gz" "$TMPD/src-$REF.tar.gz"; then
        # 브랜치·릴리스 아닌 태그. 소스 아카이브에는 SHA256SUMS 가 붙지 않는다.
        asset="src-$REF.tar.gz"
        note "릴리스 자산이 없어 소스 아카이브로 받았다: $REF"
        no_verify_gate "소스 아카이브에는 SHA256SUMS 가 붙지 않는다 — 대조할 기준이 없다."
    else
        warn "받지 못했다: https://github.com/$SLUG/releases/download/$REF/$asset"
        warn "     그 태그가 실재하는지, 그리고 네트워크가 되는지 확인해라."
        die "아카이브를 못 받았다 ($REF)"
    fi

    mkdir -p "$TMPD/x" || die "$TMPD/x 를 못 만들었다"
    tar -xzf "$TMPD/$asset" -C "$TMPD/x" || die "아카이브를 풀 수 없다: $asset"

    # 아카이브 안의 최상위 디렉토리 이름에 기대지 않는다 — bin/fmux 가 보이는 곳을 찾는다.
    root=''
    for d in "$TMPD"/x/*/; do
        [ -f "${d}bin/fmux" ] || continue
        root=${d%/}; break
    done
    [ -n "$root" ] || { [ -f "$TMPD/x/bin/fmux" ] && root="$TMPD/x"; }
    [ -n "$root" ] || die "아카이브 안에 bin/fmux 가 없다 — 이건 fleetmux 아카이브가 아니다"

    REPO="$root"
    FMUX="$REPO/bin/fmux"       # 아래 단계들이 전부 이 둘을 본다
    ok "풀었다 — 여기를 레포처럼 쓴다: $REPO"
    is_dry && note "--dry-run 이라도 받기는 받는다. 임시 디렉토리 밖으로는 한 바이트도 안 나간다."
    return 0
}

# ── ① 의존성 ────────────────────────────────────────────────────────────────
DEP_FAIL=''
dep_fail() { DEP_FAIL="$DEP_FAIL  - $1"$'\n'; }

HAVE_MAKE=0

check_deps() {
    step 1/8 "의존성"
    local v rc

    # bash — 이 스크립트를 돌리는 셸 자체. fmux 는 bash 3.2 문법만 쓴다.
    if [ -z "${BASH_VERSION:-}" ]; then
        dep_fail "bash 가 아닌 셸로 돌고 있다 — 'bash ./install.sh' 로 다시 돌려라"
    else
        ver_ge "$BASH_VERSION" 3.2; rc=$?
        if [ "$rc" = 0 ]; then ok "bash $BASH_VERSION"
        elif [ "$rc" = 1 ]; then dep_fail "bash $BASH_VERSION — 3.2 이상이 필요하다"
        else ok "bash $BASH_VERSION (버전 문자열을 못 읽었다 — 막지는 않는다)"
        fi
    fi

    # tmux — fmux 는 tmux 팝업(display-popup)으로 뜬다. 그 명령이 3.2 에 들어왔다.
    if ! command -v tmux > /dev/null 2>&1; then
        dep_fail "tmux 가 없다 — fmux 는 tmux 세션 관제탑이다. 3.2 이상(팝업 display-popup)"
    else
        v=$(tmux -V 2>/dev/null | awk 'NR==1{print $2}') || v=''
        ver_ge "$v" 3.2; rc=$?
        if [ "$rc" = 0 ]; then ok "tmux $v"
        elif [ "$rc" = 1 ]; then dep_fail "tmux $v — 3.2 이상이 필요하다(팝업 display-popup 이 3.2 부터다)"
        else warn "tmux 버전을 못 읽었다 ('${v:-빈 값}') — 3.2 이상인지 직접 확인해라"
        fi
    fi

    # fzf — 목록 UI. --footer 가 0.64 에 들어왔고 fmux 는 그걸 쓴다(90-main.sh).
    if ! command -v fzf > /dev/null 2>&1; then
        dep_fail "fzf 가 없다 — 세션 목록이 fzf 다. 0.64 이상(목록 하단 --footer)"
    else
        v=$(fzf --version 2>/dev/null | awk 'NR==1{print $1}') || v=''
        ver_ge "$v" 0.64; rc=$?
        if [ "$rc" = 0 ]; then ok "fzf $v"
        elif [ "$rc" = 1 ]; then dep_fail "fzf $v — 0.64 이상이 필요하다(fmux 가 --footer 를 쓴다)"
        else warn "fzf 버전을 못 읽었다 ('${v:-빈 값}') — 0.64 이상인지 직접 확인해라"
        fi
    fi

    # awk — 매니페스트 무결성 검사·목록 정렬·배선 판정이 전부 awk 다.
    if command -v awk > /dev/null 2>&1; then ok "awk"
    else dep_fail "awk 가 없다 — 매니페스트 검사와 목록 정렬이 awk 다"
    fi

    # flock — 있으면 좋다. 없어도 죽지 않는다: fmux 는 세 곳 전부에서
    #   `command -v flock || return 0` 로 빠져나간다(40-mfops.sh:9, 60-rc.sh:93, 70-fleet.sh:406).
    #   macOS 에는 기본으로 없다 — 여기서 막으면 맥 사용자는 아무도 설치할 수 없다.
    #   그래서 막지 않고, 무엇이 약해지는지만 말한다.
    if command -v flock > /dev/null 2>&1; then
        ok "flock"
    else
        warn "flock 이 없다 — 중복 실행 방지가 꺼진 채로 돈다(크론 라운드 겹침·부팅 복원 도플갱어)."
        warn "     설치는 계속한다. macOS 라면 'brew install flock' 으로 넣을 수 있다."
    fi

    # make — 있으면 make install 을 쓰고, 없으면 커밋된 bin/fmux 를 직접 복사한다.
    if command -v make > /dev/null 2>&1; then HAVE_MAKE=1; ok "make"
    else warn "make 가 없다 — 커밋된 bin/fmux 를 그대로 복사한다(빌드는 건너뛴다)"
    fi

    if [ -n "$DEP_FAIL" ]; then
        printf '\n필요한 것이 빠졌거나 낮다:\n%s' "$DEP_FAIL" >&2
        die "의존성이 안 맞는다"
    fi
}

# ── ② 바이너리 ─────────────────────────────────────────────────────────────
install_bin() {
    step 2/8 "바이너리 — $BINDIR"

    [ -f "$REPO/bin/fmux" ] || die "$REPO/bin/fmux 가 없다 — 레포가 온전한지 확인해라"

    # 빌드가 먼저다. 그래야 아래 cmp 가 "지금 설치될 것"과 비교한다.
    #   원격 모드는 빌드하지 않는다 — **SHA256 로 대조한 그 바이트를 그대로 깐다.**
    #   여기서 다시 이어붙이면 설치되는 것이 대조한 것과 다를 수 있고, 그러면 대조의 뜻이 없다.
    if [ "$HAVE_MAKE" = 1 ] && [ "$REMOTE" = 0 ] && ! is_dry; then
        if ! make -C "$REPO" > /dev/null; then
            die "make 가 실패했다 — 'make' 를 직접 돌려 이유를 봐라"
        fi
    fi

    if [ -e "$BINDIR/fmux" ]; then
        if cmp -s "$REPO/bin/fmux" "$BINDIR/fmux"; then
            ok "$BINDIR/fmux 이미 같은 내용 — 그대로 둔다"
        else
            note "$BINDIR/fmux 가 이미 있고 내용이 다르다 → 덮는다"
        fi
    fi

    if is_dry; then
        plan "mkdir -p $BINDIR && cp bin/fmux $BINDIR/fmux (make install PREFIX=$PREFIX)"
        if tt_link_absent || tt_link_ours; then
            plan "ln -sf fmux $BINDIR/tt   (심링크 — shim 이 PATH 의 'tt' 를 찾는다)"
        else
            plan "$BINDIR/tt 는 우리 것이 아니다($(tt_link_what)) → 건드리지 않는다(훅 주입이 안 붙는다)"
        fi
    else
        if [ "$HAVE_MAKE" = 1 ] && [ "$REMOTE" = 0 ]; then
            # Makefile 의 install 이 fmux 복사와 tt 심링크를 같이 한다 — `make install` 만 쳐도
            # 쓸 수 있는 상태가 되어야 하기 때문이다. 여기서는 결과만 확인한다.
            # (원격 모드는 여기로 안 온다 — 대조한 바이트를 그대로 복사한다. 아래 else 가 그 길이고,
            #  tt 심링크 판정은 Makefile 과 같은 규칙이다.)
            make -C "$REPO" install PREFIX="$PREFIX" > /dev/null || die "make install 이 실패했다 (PREFIX=$PREFIX)"
        else
            mkdir -p "$BINDIR" || die "$BINDIR 를 만들 수 없다"
            cp "$REPO/bin/fmux" "$BINDIR/fmux" || die "$BINDIR/fmux 를 쓸 수 없다"
            chmod +x "$BINDIR/fmux" || die "$BINDIR/fmux 에 실행권한을 못 준다"
            if tt_link_absent || tt_link_ours; then ln -sf fmux "$BINDIR/tt"; fi
        fi
        [ -x "$BINDIR/fmux" ] || die "$BINDIR/fmux 가 설치되지 않았다"
        did "$BINDIR/fmux"
        ok "$BINDIR/fmux"
        FMUX="$BINDIR/fmux"

        # tt 심링크 — shim(libexec/claude)이 `command -v tt` 로 우리 존재를 확인한다.
        # 그 이름이 남의 것이면 건드리지 않고, **무엇이 있는지 보여주고 사람이 정하게 한다**.
        # 되돌릴 수 없는 일은 설치기가 혼자 결정하지 않는다(게이트 I2).
        if tt_link_ours; then
            did "$BINDIR/tt → fmux"
            ok "$BINDIR/tt → fmux"
        elif tt_link_absent; then
            warn "$BINDIR/tt 심링크를 못 만들었다 — 'ln -sf fmux $BINDIR/tt' 를 직접 쳐라"
        else
            warn "$BINDIR/tt 는 우리 것이 아니다 — 건드리지 않았다."
            warn "     지금 그 자리: $(tt_link_what)"
            warn "     남의 tt 를 말없이 빼앗지 않는다. 어떻게 할지는 네가 정해라:"
            warn "       ① 그 도구를 계속 쓴다 — fmux 는 'fmux' 이름으로 그대로 쓸 수 있다."
            warn "          다만 shim 은 PATH 의 'tt' 를 찾으므로 훅 주입이 안 붙는다(상태 마크가 안 뜬다)."
            warn "       ② fmux 에게 이 이름을 준다 — 먼저 그 자리를 네 손으로 치워라:"
            warn "          mv $BINDIR/tt $BINDIR/tt.yours && ln -sf fmux $BINDIR/tt"
            warn "       ③ PATH 의 다른 디렉토리에 'tt' 라는 이름으로 걸어도 shim 은 그걸 찾는다."
        fi

        # 설치된 놈이 실제로 도는지 한 번 물어본다(tmux 를 안 부르는 문으로).
        "$BINDIR/fmux" config path > /dev/null 2>&1 || warn "설치된 fmux 가 'config path' 에 답하지 않는다 — 직접 돌려봐라"
    fi

    case ":$PATH:" in
        *":$BINDIR:"*) ok "PATH 에 $BINDIR 가 있다" ;;
        *) note "PATH 에 $BINDIR 가 없다. $(rc_hint) 에 이 줄을 넣어라 (자동으로 안 고친다):"
           note "    $(path_line)" ;;
    esac
}

# ── ③ 훅 shim ──────────────────────────────────────────────────────────────
install_shims() {
    step 3/8 "훅 shim — $LIBEXEC"
    note "shim 은 tmux 안에서 뜬 claude/codex 에만 훅을 --settings 로 붙인다 —"
    note "  전역 설정(~/.claude/settings.json)은 안 건드리고, 이 파일을 지우면 흔적이 사라진다."

    local f name real_i shim_i
    for name in claude codex; do
        f="$REPO/libexec/$name"
        [ -f "$f" ] || die "$f 가 없다 — 레포가 온전한지 확인해라"
    done

    for name in claude codex; do
        if [ -e "$LIBEXEC/$name" ]; then
            if cmp -s "$REPO/libexec/$name" "$LIBEXEC/$name"; then
                ok "$LIBEXEC/$name 이미 같은 내용 — 그대로 둔다"
                continue
            fi
            note "$LIBEXEC/$name 이 이미 있고 내용이 다르다 → 덮는다"
        fi
        if is_dry; then
            plan "cp libexec/$name $LIBEXEC/$name"
        else
            mkdir -p "$LIBEXEC" || die "$LIBEXEC 를 만들 수 없다"
            cp "$REPO/libexec/$name" "$LIBEXEC/$name" || die "$LIBEXEC/$name 을 쓸 수 없다"
            chmod +x "$LIBEXEC/$name" || die "$LIBEXEC/$name 에 실행권한을 못 준다"
            did "$LIBEXEC/$name"
            ok "$LIBEXEC/$name"
        fi
    done

    # PATH 순서 — shim 이 진짜 claude 보다 **앞**이어야 한다. 뒤면 맨 claude 가 떠서
    # 훅이 하나도 안 오고, 함대 상태판이 통째로 조용히 죽는다(가장 흔한 설치 실패다).
    shim_i=$(path_index "$LIBEXEC")
    if [ "$shim_i" = 0 ]; then
        note "PATH 에 $LIBEXEC 가 없다 — 지금은 훅이 안 붙는다. $(rc_hint) 에:"
        note "    $(path_line)"
    else
        for name in claude codex; do
            real_i=$(first_real_index "$name")
            if [ "$real_i" = 0 ]; then
                note "$name 을 PATH 에서 못 찾았다 — 나중에 깔면 shim 이 앞선다(PATH 순서가 그대로라면)"
            elif [ "$shim_i" -lt "$real_i" ]; then
                ok "PATH 순서 좋다 — shim($shim_i) 이 진짜 $name($real_i) 보다 앞이다"
            else
                warn "PATH 에서 진짜 $name($real_i) 이 shim($shim_i) 보다 앞이다 — 훅이 안 붙는다."
                warn "     $LIBEXEC 를 PATH 맨 앞으로 올려라: $(path_line)"
            fi
        done
    fi
}

# ── ④ tmux 스니펫 ──────────────────────────────────────────────────────────
SNIP=''
TMUXCONF=''

snip_path() {
    # 경로를 여기서 다시 조립하지 않는다 — fmux 가 자기 머리말에 찍는 값을 읽는다.
    # (그래도 못 읽으면 05-config.sh 와 같은 규칙으로 접는다.)
    local p=''
    p=$("$FMUX" --tmux-conf 2>/dev/null | awk '$1=="#" && $2=="source-file" {print $3; exit}') || p=''
    [ -n "$p" ] || p="${XDG_CONFIG_HOME:-$HOME/.config}/fleetmux/tmux.conf"
    printf '%s' "$p"
}

# tmux 가 읽는 사용자 설정 자리를 고른다. 있는 파일이 있으면 그걸 쓴다 —
# ~/.config/tmux/tmux.conf 를 쓰는 사람의 ~/.tmux.conf 에 줄을 넣으면 "넣었는데 아무 일도
# 안 일어난다" 가 된다. 둘 다 없으면 전통적인 자리(~/.tmux.conf)로 간다.
pick_tmux_conf() {
    local x="${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf"
    if [ -f "$HOME/.tmux.conf" ]; then printf '%s' "$HOME/.tmux.conf"
    elif [ -f "$x" ]; then printf '%s' "$x"
    else printf '%s' "$HOME/.tmux.conf"
    fi
}

# 이미 source 하고 있나 — 주석 줄은 세지 않는다.
#   판정은 **줄 앞머리 한정 + 인자 정확 일치**여야 한다. 예전엔 `*source*<경로>*` 부분일치라,
#   개행 없이 끝난 파일에 append 해 깨진 줄("set -g mouse onsource-file …")까지 "이미 설정됨"
#   으로 통과시켰다 — 재실행이 자가치유를 못 하고 파손이 영구히 가려졌다(게이트 B2).
#   fmux 쪽 판정(87-tmux-conf.sh 의 tt_tmux_conf_linked)과 같은 규칙이어야 한다.
already_sourced() {   # $1=설정파일  $2=스니펫경로
    local line rest
    [ -r "$1" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        while :; do case "$line" in [[:blank:]]*) line=${line#?} ;; *) break ;; esac; done
        case "$line" in
            'source-file '*) rest=${line#source-file } ;;
            'source '*)      rest=${line#source } ;;
            *) continue ;;
        esac
        # 앞의 플래그(-q 등)를 걷고, 뒤 공백·인용부호를 벗긴 뒤 정확히 비교한다.
        # 낱말 분해로 돌지 않는 이유: 남의 설정 줄에 있는 * 가 파일명으로 펴진다.
        while :; do case "$rest" in '-'*' '*) rest=${rest#* } ;; *) break ;; esac; done
        while :; do case "$rest" in *[[:blank:]]) rest=${rest%?} ;; *) break ;; esac; done
        case "$rest" in '"'*'"'|"'"*"'") rest=${rest#?}; rest=${rest%?} ;; esac
        # 틸데(~/…)는 펴서 본다 — README 가 가르치는 모양이고 tmux 도 그렇게 읽는다(게이트 I1).
        # 안 펴면 문서대로 손으로 넣은 사람에게 재실행이 **중복 source 줄**을 하나 더 붙인다.
        # 패턴을 \~ 로 인용하는 이유: bash 는 ${var#word} 의 word 에도 틸데 확장을 한다.
        case "$rest" in
            '~')   rest="$HOME" ;;
            '~/'*) rest="$HOME/${rest#\~/}" ;;
        esac
        [ "$rest" = "$2" ] && return 0
    done < "$1"
    return 1
}

# 남의 파일에 한 줄 붙이는 유일한 자리 — 여기만큼은 과하게 조심한다(게이트 B1).
#   ① 고치기 전에 원본을 통째로 백업하고 그 경로를 사람에게 말한다.
#   ② 마지막 바이트가 개행이 아니면 개행부터 넣는다. `>>` 만 쓰면 사용자의 마지막 줄에
#      우리 줄이 그대로 이어붙어 그 줄이 파괴된다(그리고 rc 0 "성공"으로 보고된다).
#   `tail -c 1` 은 POSIX 다(GNU 전용 아님). 명령치환은 끝의 개행을 지우므로,
#   결과가 비어 있으면 마지막 바이트가 개행이라는 뜻이다.
append_source_line() {   # $1=설정파일  $2=스니펫경로  → rc 0 이면 넣었다
    local f="$1" snip="$2" last
    if [ -s "$f" ]; then
        cp "$f" "$f.fmux-bak" || { warn "$f 를 백업하지 못했다 — 아무것도 안 고친다"; return 1; }
        ok "백업해 뒀다: $f.fmux-bak  (되돌리려면 이 파일을 되돌려 놓으면 된다)"
        last=$(tail -c 1 "$f" 2>/dev/null) || last=''
        if [ -n "$last" ]; then
            note "$f 가 개행으로 끝나지 않는다 — 마지막 줄이 깨지지 않게 개행부터 넣는다"
            printf '\n' >> "$f" || return 1
        fi
    fi
    printf 'source-file %s\n' "$snip" >> "$f" || return 1
    return 0
}

# 순서가 규율이다(게이트 B5): **동의 → 남의 파일 한 줄 → 우리 스니펫 쓰기**.
#   예전엔 스니펫을 먼저 썼다. 그 write 는 tmux 안이면 살아있는 서버에 source-file 을 쏘므로,
#   "넣을까요?" 를 묻기도 전에 이미 적용되고, n 을 눌러도 안내문은 "안 넣었다"고 말했다.
#   지금은 fmux 쪽에도 게이트가 있다(tt_tmux_conf_linked) — 사용자 설정에 줄이 있을 때만
#   반영한다. 그래서 이 순서면 "동의한 사람만 이번 서버에도 반영된다"가 양쪽에서 성립한다.
install_snippet() {
    step 4/8 "tmux 스니펫"
    SNIP=$(snip_path)          # 파일을 안 쓰고 경로만 묻는다(--write 아님)
    TMUXCONF=$(pick_tmux_conf)
    local linked=0 out

    if already_sourced "$TMUXCONF" "$SNIP"; then
        linked=1
        ok "$TMUXCONF 가 이미 이 파일을 source 한다 — 아무것도 안 넣는다"
    else
        printf '  넣을 줄: source-file %s\n' "$SNIP"
        printf '  넣을 곳: %s\n' "$TMUXCONF"
        if ask_yn "$TMUXCONF 에 이 한 줄을 넣을까?"; then
            if is_dry; then
                plan "$TMUXCONF 를 $TMUXCONF.fmux-bak 로 백업한 뒤 source-file $SNIP 한 줄 추가"
            else
                append_source_line "$TMUXCONF" "$SNIP" || die "$TMUXCONF 에 못 썼다"
                linked=1
                did "$TMUXCONF 에 source-file 한 줄"
                ok "$TMUXCONF 에 한 줄 넣었다"
                note "이미 tmux 안이라면 prefix + : 로 'source-file $TMUXCONF' 를 한 번 쳐라(또는 새 tmux 서버)"
            fi
        else
            note "안 넣었다. 위 한 줄을 직접 $TMUXCONF 에 넣으면 소환키가 산다."
            note "  넣기 전까지는 우리 스니펫이 어떤 tmux 서버에도 반영되지 않는다 — 파일만 만들어 둔다."
        fi
    fi

    # 이제 스니펫을 쓴다. 이 파일은 우리 것이라 동의 없이 만들어도 되지만, 살아있는 서버에
    # 반영되는 것은 위에서 linked 가 된 사람뿐이다(fmux 안의 게이트가 같은 판정을 한다).
    if is_dry; then
        plan "$FMUX --tmux-conf --write   → $SNIP"
    else
        out=$("$FMUX" --tmux-conf --write) || die "스니펫을 쓸 수 없다: $SNIP"
        [ -n "$out" ] && SNIP="$out"
        did "$SNIP (tmux 스니펫)"
        ok "$SNIP"
    fi
    note "이 파일은 fmux 것이다 — 소환키·떠날 때 스냅샷 훅이 들어 있고, 설정을 바꾸면 다시 쓰인다."
    [ "$linked" = 1 ] || note "아직 아무 tmux 설정도 이 파일을 안 읽는다 — 소환키는 연결한 뒤에 산다."
    return 0
}

# ── ⑤ 소환키 프리셋 ────────────────────────────────────────────────────────
# 물리 키 하나가 터미널마다 다른 이름으로 도착한다 — 그래서 목록이다(87-tmux-conf.sh).
#
# ── 왜 제안이 S-Left 인가 (이 판단의 근거를 여기 남긴다) ─────────────────────
# prefix 방식은 거부됐다: "두 번 눌러야 되잖아". 원하는 것은 무prefix 한 타건이다.
# 조합을 훑으면 **Shift+방향키가 세 플랫폼을 다 통과하는 유일한 한 타건**이다:
#
#   C-화살표 : macOS 의 Mission Control 이 가져간다(스페이스 전환·창 보기)
#   M-화살표 : macOS 는 Option 을 ESC b 로 보내고, Windows Terminal 은 Alt+화살표를 먼저 먹는다
#   Ctrl+글자: 거의 전부 셸 줄편집·vim·emacs·fzf 위젯이 이미 쓴다
#   S-화살표 : 세 플랫폼 모두 통과. 손도 안 멀다(방향키 옆이 Shift)
#
# 방향이 **왼쪽**인 이유는 취향이 아니라 이미 형성된 조작 모델이다:
#   - 사용자는 몇 주간 C-Left·M-Left 로 왼쪽에서 팝업을 불러 왔다. S-Left 는 그 손버릇을 잇는다.
#   - 팝업 안에서는 → 가 진입(accept), ← 가 닫기(abort)다. 그 관례는 그대로 둔다 —
#     ranger·lf·nnn·vifm 등 TUI 계열의 보편 관례이고, 팀원 둘이 이미 그렇게 설치했다.
#   - "밖에서 왼쪽은 부르기, 안에서 왼쪽은 닫기"는 맥락이 달라 안 헷갈린다(실사용으로 확인).
#
# 알려진 위험 하나 — 정직하게 적는다: **S-Left/S-Right 를 tmux 창 전환에 바인딩한 dotfile 이
# 흔하다.** 그래서 아래 preset_conflicts 가 설정 파일을 먼저 읽어 알려주고, 그런 사람은
# 설치 때 다른 프리셋을 고르면 된다.
#
# 정책은 둘로 갈린다(05-config.sh 의 key_summon_fast 기본값 주석과 짝이다):
#   설정 기본값 = 빈 값(아무 키도 안 뺏음)  ·  설치기의 제안 = shift(S-Left)
# 제안은 사람이 눈으로 보고 "예"라고 말할 자리가 있을 때만 유효하다. 그래서 --yes 와
# 터미널 아닌 자리는 여전히 safe 로 간다 — 자동 승인이 남의 키를 가져가면 안 된다.
preset_value() {
    case "${1:-}" in
        safe)  printf '' ;;
        shift) printf 'S-Left' ;;
        mac)   printf 'M-b' ;;
        linux) printf 'C-Left M-Left' ;;
        wsl)   printf 'C-Left' ;;
        *)     return 1 ;;
    esac
    return 0
}

preset_why() {
    case "${1:-}" in
        safe)  printf 'prefix 뒤의 소환키만 쓴다 — 남의 키를 하나도 안 뺏는다' ;;
        shift) printf '맥·리눅스·Windows Terminal 세 곳 모두에 도착하는 유일한 무prefix 한 타건' ;;
        mac)   printf '맥의 Option+← 는 터미널이 ESC b 로 보내 M-b 로 도착한다' ;;
        linux) printf '터미널마다 C-Left 또는 M-Left 로 온다 — 둘 다 건다' ;;
        wsl)   printf 'Windows Terminal 이 Alt+화살표를 자기가 먼저 먹는다 — C-Left 만 남는다' ;;
    esac
}

# 프롬프트가 기본으로 내미는 프리셋. 플랫폼 감지값이 아니다 — 세 플랫폼 공통으로 되는
# 하나(S-Left)를 내민다. 감지값은 여전히 화면에 뜨지만 그건 "이 기계는 이렇게 보인다"는
# 정보이지 제안이 아니다.
PRESET_SUGGEST=shift

# 프리셋이 걸 키를 사용자가 이미 자기 설정에서 쓰고 있나 — 덮기 전에 알리기 위해서다.
# 살아있는 tmux 서버에 묻지 않는다(list-keys): 설치기는 서버가 없어도 돌아야 하고, 남의
# 서버에 말을 거는 것 자체가 이 프로젝트가 안 하는 일이다. 그래서 **설정 파일만** 읽는다.
# 그래서 이 감지는 완전하지 않다 — 파일에 없는 바인딩(다른 스니펫이 source 한 것, 손으로
# 친 것)은 못 본다. 그 한계 때문에 제안 문구에 "이미 쓰고 있다면 다른 키를 골라라"를 같이 적는다.
preset_conflicts() {   # $1=키 목록(공백 구분) → "키  파일:줄  그 줄 전문" 을 줄마다
    local keys="${1:-}" f line k n raw
    [ -n "$keys" ] || return 0
    for f in "$HOME/.tmux.conf" "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf"; do
        [ -r "$f" ] || continue
        # 우리 스니펫은 후보가 아니다 — 우리가 지난번에 건 것을 "남의 키"라 말하면 거짓이다.
        [ "$f" = "${SNIP:-}" ] && continue
        n=0
        while IFS= read -r line || [ -n "$line" ]; do
            n=$((n + 1))
            raw="$line"
            while :; do case "$line" in [[:blank:]]*) line=${line#?} ;; *) break ;; esac; done
            case "$line" in 'bind '*|'bind-key '*) ;; *) continue ;; esac
            for k in $keys; do
                # 낱말 경계로 본다 — 양옆에 공백을 붙여 부분일치(C-Left 안의 Left)를 막는다.
                case " $line " in *" $k "*) printf '%s  %s:%s  %s\n' "$k" "$f" "$n" "$raw" ;; esac
            done
        done < "$f"
    done
    return 0
}

detect_preset() {
    case "$(uname -s 2>/dev/null || echo unknown)" in
        Darwin) printf 'mac'; return 0 ;;
    esac
    if [ -n "${WSL_DISTRO_NAME:-}" ] || [ -n "${WSLENV:-}" ]; then printf 'wsl'; return 0; fi
    if [ -r /proc/version ]; then
        case "$(cat /proc/version 2>/dev/null)" in
            *[Mm]icrosoft*|*WSL*) printf 'wsl'; return 0 ;;
        esac
    fi
    printf 'linux'
}

install_preset() {
    step 5/8 "소환키"
    local guess want cur v clash sug line

    guess=$(detect_preset)
    sug=$(preset_value "$PRESET_SUGGEST")

    # 제안은 어느 분기로 가든 **먼저, 똑같이** 화면에 뜬다. --yes 나 CI 에서 돌린 사람도
    # "무엇을 안 받았고 어떻게 받는지"를 그 자리에서 봐야 하기 때문이다. 결정만 분기가 가른다.
    note "제안: $PRESET_SUGGEST — key_summon_fast='$sug' ($(preset_why "$PRESET_SUGGEST"))"
    note "  이 키를 pane 안 모든 앱에서 가져갑니다 — vim·셸 줄편집·fzf 가 그 pane 에서 S-Left 를 못 본다."
    note "  S-Left/S-Right 를 tmux 창 전환에 걸어 둔 dotfile 이 흔하다. 이미 쓰고 있다면 다른 키를 골라라."
    clash=$(preset_conflicts "$sug")
    if [ -n "$clash" ]; then
        warn "이미 그 키를 거는 줄을 설정에서 찾았다 — 프리셋을 고르면 우리 바인딩이 이깁니다:"
        printf '%s\n' "$clash" | while IFS= read -r line; do printf '      %s\n' "$line"; done
    fi

    if [ -n "$PRESET" ]; then
        preset_value "$PRESET" > /dev/null 2>&1 || die "모르는 프리셋: $PRESET (safe|shift|mac|linux|wsl)"
        want="$PRESET"
        note "프리셋을 인자로 받았다: $want"
    elif [ "$ASSUME_YES" = 1 ]; then
        # --yes 는 **safe 로 간다**(팀 배포 게이트 I3). 예전엔 감지 프리셋을 자동 채택했다 —
        # 리눅스에서 `./install.sh --yes` 가 무prefix 키 두 개(C-Left M-Left)를 말없이 전역으로
        # 뺏었고, 그동안 README 는 "steals no key until you say so" 를 약속하고 있었다.
        # 키를 뺏는 것은 되돌리기 귀찮은 전역 변경이라 "기본값 수락"의 범주가 아니다 —
        # 사람이 --preset 으로 **명시**할 때만 뺏는다. 제안이 S-Left 로 바뀐 뒤에도 이 규칙은
        # 그대로다 — 제안이 좋아졌다는 것과 동의 없이 가져가도 된다는 것은 다른 말이다.
        want=safe
        note "--yes 는 아무 키도 안 뺏는 safe 로 간다 — 무prefix 키는 명시할 때만 뺏는다"
        note "  한 타건을 원하면: ./install.sh --yes --preset $PRESET_SUGGEST   (이 기계는 $guess 로 보인다)"
    elif [ "$ASK_TTY" = 0 ]; then
        # 무prefix 바인딩은 남의 키를 뺏는 일이다. 물을 수 없는 자리에서는 안 뺏는 쪽으로 간다.
        want=safe
        note "터미널이 아니라 묻지 않았다 — 아무 키도 안 뺏는 safe 로 간다"
        note "  한 타건을 원하면: ./install.sh --preset $PRESET_SUGGEST   (이 기계는 $guess 로 보인다)"
    else
        note "고를 수 있는 것:"
        note "shift  S-Left — 위에 적은 그 제안 (기본값)"
        note "safe   무prefix 없음 — $(preset_why safe)"
        note "mac    M-b — $(preset_why mac)"
        note "linux  C-Left M-Left — $(preset_why linux)"
        note "wsl    C-Left — $(preset_why wsl)"
        note "감지: $(uname -s 2>/dev/null || echo unknown) → $guess. 그래도 제안은 $PRESET_SUGGEST 다 —"
        note "  mac·linux·wsl 프리셋은 각자 자기 플랫폼에서만 되고, 셋 다에서 되는 것은 S-Left 하나다."
        note "  거절하면(safe) prefix 방식으로 간다 — prefix 뒤에 소환키를 누른다. 아무 키도 안 뺏는다."
        want=$(ask_word "프리셋 (shift|safe|mac|linux|wsl)" "$PRESET_SUGGEST")
        if ! preset_value "$want" > /dev/null 2>&1; then
            warn "모르는 프리셋 '$want' — safe 로 간다"
            want=safe
        fi
    fi
    v=$(preset_value "$want")
    note "$want: key_summon_fast='$v' — $(preset_why "$want")"
    # 제안이 아닌 키를 골랐으면 그 키로 다시 잰다 — 위에서 잰 것은 S-Left 였다.
    if [ "$want" != "$PRESET_SUGGEST" ] && [ -n "$v" ]; then
        clash=$(preset_conflicts "$v")
        if [ -n "$clash" ]; then
            warn "고른 키를 이미 거는 줄이 설정에 있다 — 우리 바인딩이 이깁니다:"
            printf '%s\n' "$clash" | while IFS= read -r line; do printf '      %s\n' "$line"; done
        fi
    fi
    note "prefix 뒤 소환키(key_summon)는 그대로 둔다 — 바꾸려면 tt config set key_summon <키>"

    cur=$("$FMUX" config get key_summon_fast 2>/dev/null) || cur=''
    if [ "$cur" = "$v" ]; then
        ok "key_summon_fast 가 이미 '$v' 다 — 그대로 둔다"
        return 0
    fi

    if is_dry; then
        if [ -z "$v" ]; then plan "fmux config unset key_summon_fast   (지금: '$cur')"
        else plan "fmux config set key_summon_fast '$v'   (지금: '$cur')"; fi
        return 0
    fi

    # config set/unset 은 스니펫을 스스로 다시 쓴다(85-config-cli.sh 의 tt_conf_resnip).
    if [ -z "$v" ]; then
        "$FMUX" config unset key_summon_fast > /dev/null || die "key_summon_fast 를 못 지웠다"
        did "설정 key_summon_fast 제거(safe)"
    else
        "$FMUX" config set key_summon_fast "$v" > /dev/null || die "key_summon_fast 를 못 넣었다"
        did "설정 key_summon_fast='$v'"
    fi
    ok "key_summon_fast='$v' (스니펫도 같이 다시 쓰였다)"
}

# ── ⑥ 에이전트 스킬 ────────────────────────────────────────────────────────
SKILL_SRC=''
SKILL_DST=''
SKILL_BAK=''

# 우리 복사(cp -R "$SKILL_SRC/." "$SKILL_DST/")가 **덮어쓸 남의 내용**을 한 줄에 하나씩.
# 비면 잃을 것이 없다는 뜻이다 — 그때는 백업을 만들 이유도 없다.
#   왜 "디렉토리가 다르다"가 아니라 이걸 재나: cp 는 병합이라, SRC 에 없는 파일(사용자가 옆에
#   둔 메모 등)은 애초에 위험하지 않다. 그걸 '다름'으로 세면 재실행마다 백업이 하나씩 쌓인다.
skill_clobber_list() {
    local f rel
    [ -n "$SKILL_SRC" ] && [ -e "$SKILL_DST" ] || return 0
    if [ ! -d "$SKILL_DST" ]; then printf '%s\n' "$SKILL_DST"; return 0; fi
    # find 는 POSIX. 디렉토리는 안 센다 — cp -R 이 디렉토리를 지우지는 않는다.
    find "$SKILL_SRC" -type f 2>/dev/null | while IFS= read -r f; do
        rel=${f#"$SKILL_SRC"/}
        [ -e "$SKILL_DST/$rel" ] || continue
        cmp -s "$f" "$SKILL_DST/$rel" || printf '%s\n' "$rel"
    done
}

install_skill() {
    step 6/8 "에이전트 스킬"
    local clob=''
    SKILL_SRC="$REPO/skills/fleetmux"
    SKILL_DST="$HOME/.claude/skills/fleetmux"

    if [ ! -f "$SKILL_SRC/SKILL.md" ]; then
        skip "이 레포에 skills/fleetmux/SKILL.md 가 없다 — 건너뛴다"
        SKILL_SRC=''
        SKILL_DST=''      # 안 깔았으면 '지우려면' 목록에도 나오면 안 된다
        return 0
    fi

    if [ -e "$SKILL_DST" ]; then
        note "$SKILL_DST 가 이미 있다 → 덮어쓴다(우리가 넣은 파일만)"
        note "  덮을 남의 내용이 있으면 그 전에 $SKILL_DST.fmux-bak 로 통째로 백업한다"
        note "  그 백업이 이미 있으면 그건 네 원본이다 — 덮지 않고 타임스탬프를 붙여 옆에 남긴다"
    fi
    if ask_yn "에이전트 스킬을 $SKILL_DST 에 깔까?"; then
        if is_dry; then
            plan "mkdir -p $SKILL_DST && cp -R skills/fleetmux/. $SKILL_DST/"
        else
            # 남의 파일을 되돌릴 수 없게 덮지 않는다 — 우리 이름과 같은 스킬을 이미 쓰던
            # 사람에게 --yes 는 "제안된 기본값 수락"이지 "네 스킬을 버려라"가 아니다(권고 N1).
            #
            # ⚠️ **백업은 한 번 만들면 절대 덮지 않는다**(팀 배포 게이트 C3). 예전엔 여기서
            #   `rm -rf "$SKILL_DST.fmux-bak"` 로 시작했다 — 2회차 실행이 1회차가 남긴
            #   **사용자 원본**을 먼저 지우고, 이미 우리 파일로 덮인 디렉토리를 그 자리에 다시
            #   백업했다. 화면은 두 번 다 "백업해 뒀다"를 찍는데 사용자 원본은 기계 어디에도
            #   안 남는다. 재실행이 안전하다는 README 의 약속을 정면으로 어긴 자리다.
            #   지금 규칙: ① 우리 복사가 덮어쓸 남의 내용이 하나도 없으면 백업하지 않는다
            #   (재실행마다 사본이 쌓이는 것도 그 자체로 사고다) ② .fmux-bak 이 이미 있으면
            #   그건 원본이다 — 손대지 않고 이번 것만 타임스탬프를 붙여 옆에 남긴다.
            clob=$(skill_clobber_list)
            if [ -e "$SKILL_DST" ] && [ -z "$clob" ]; then
                ok "$SKILL_DST 에 우리가 덮어쓸 남의 내용이 없다 — 백업할 것이 없다"
            elif [ -e "$SKILL_DST" ]; then
                note "덮어쓸 파일: $(printf '%s' "$clob" | tr '\n' ' ')"
                SKILL_BAK="$SKILL_DST.fmux-bak"
                if [ -e "$SKILL_BAK" ]; then
                    note "$SKILL_BAK 이 이미 있다 — 그건 첫 실행이 남긴 네 원본이다. 덮지 않는다."
                    # 초가 같은 두 실행이 같은 이름을 잡으면 백업이 백업 안에 겹쳐 들어간다.
                    # $$ 로 실행마다 갈라 놓는다.
                    SKILL_BAK="$SKILL_DST.fmux-bak.$(date +%Y%m%d-%H%M%S).$$"
                fi
                cp -R "$SKILL_DST" "$SKILL_BAK" \
                    || die "$SKILL_DST 를 백업하지 못했다 — 덮지 않고 멈춘다"
                did "$SKILL_BAK (덮기 전 백업)"
                ok "백업해 뒀다: $SKILL_BAK"
            fi
            mkdir -p "$SKILL_DST" || die "$SKILL_DST 를 만들 수 없다"
            cp -R "$SKILL_SRC/." "$SKILL_DST/" || die "$SKILL_DST 로 못 복사했다"
            did "$SKILL_DST/"
            ok "$SKILL_DST/"
        fi
    else
        SKILL_DST=''
        note "안 깔았다. 나중에: cp -R $SKILL_SRC/. ~/.claude/skills/fleetmux/"
    fi
}

# ── ⑦ 크론 안내 (보여주기만 한다) ──────────────────────────────────────────
show_cron() {
    step 7/8 "크론 — 보여주기만 한다"
    note "crontab 은 이 스크립트가 절대 안 고친다. 원하면 'crontab -e' 로 직접 넣어라:"
    printf '\n'
    printf '    * * * * * %s/fmux --cron >/dev/null 2>&1\n' "$BINDIR"
    printf '    @reboot %s/fmux --boot-restore >/dev/null 2>&1\n' "$BINDIR"
    printf '\n'
    note "첫 줄: 1분마다 rc 자동복구 + 함대 스냅샷(매니페스트가 늘 1분 안쪽으로 최신)"
    note "둘째 줄: 부팅 뒤 세션·대화 복원. 끄고 싶은 날은 touch ~/.cache/tt/no-autorestore"
    note "둘 다 tt config 로도 끌 수 있다: tt config set rc off / snapshot off / boot_restore off"
}

# ── ⑧ 요약 ─────────────────────────────────────────────────────────────────
summary() {
    step 8/8 "요약"
    local fastnow
    if is_dry; then
        printf '  --dry-run 이었다 — 파일을 하나도 안 만들었다. 위 dry 줄이 할 일이다.\n'
        printf '  실제로 하려면: ./install.sh\n'
        return 0
    fi

    printf '\n무엇이 어디에 있나\n'
    printf '%s' "$DID"

    printf '\n다음 한 걸음\n'
    case ":$PATH:" in
        *":$BINDIR:"*) printf '  - 새 tmux 세션에서 tt 를 쳐봐라 (또는 prefix + %s)\n' "$("$FMUX" config get key_summon 2>/dev/null || echo F)" ;;
        *) printf '  - PATH 를 먼저 고쳐라: %s\n' "$(path_line)" ;;
    esac
    # 무prefix 키가 실제로 걸렸으면 그 키를 말한다. 안 걸렸으면 어떻게 얻는지를 말한다 —
    # 화면과 문서가 다른 말을 하면 안 되고, "안 뺏었다"도 결과의 일부다.
    fastnow=$("$FMUX" config get key_summon_fast 2>/dev/null) || fastnow=''
    if [ -n "$fastnow" ]; then
        printf '  - 무prefix 한 타건도 걸렸다: %s  (되돌리려면 tt config unset key_summon_fast)\n' "$fastnow"
    else
        printf '  - 무prefix 한 타건은 안 걸었다 — 원하면: tt config set key_summon_fast %s\n' "$(preset_value "$PRESET_SUGGEST")"
    fi
    printf '  - tt --help 가 키·설정·복원을 전부 설명한다. tt config list 로 설정을 본다.\n'

    printf '\n지우려면\n'
    printf '  rm -f  %s/fmux %s/tt\n' "$BINDIR" "$BINDIR"
    printf '  rm -rf %s\n' "$LIBEXEC"
    printf '  rm -f  %s\n' "$SNIP"
    printf '  rm -rf %s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/fleetmux"
    printf '  rm -rf %s/.cache/tt   (상태·로그 — 지워도 잃는 건 이력뿐)\n' "$HOME"
    printf "  %s 의 'source-file %s' 줄 삭제\n" "$TMUXCONF" "$SNIP"
    [ -n "$SKILL_DST" ] && printf '  rm -rf %s\n' "$SKILL_DST"
    printf '  crontab 에 넣은 줄이 있으면 crontab -e 로 직접 지운다\n'
    printf '  ※ 위 줄을 그대로 치기 전에 그 자리에 네 파일이 섞여 있지 않은지 한 번 봐라.\n'
    printf '    우리가 덮기 전에 남긴 백업은 전부 <원본>.fmux-bak 이다.\n'
}

# ── 본체 ────────────────────────────────────────────────────────────────────
# 무엇이 일어나는지 사용자가 먼저 알아야 한다 — 어느 모드로 가는지 한 줄로 밝히고 시작한다.
printf 'fleetmux 설치\n'
if [ "$REMOTE" = 1 ]; then
    printf '  모드   원격 — 여기(%s)에 레포가 없다. 릴리스 아카이브를 받아 설치한다.\n' "$REPO"
    printf '         받을 것: %s\n' "${REF:-최신 릴리스 태그(정해서 알려준다)}"
else
    printf '  모드   로컬 — 옆에 레포가 있다. 그 bin/fmux 를 설치한다.\n'
    printf '  레포   %s\n' "$REPO"
    [ -n "$REF" ] && printf '  참고   --ref %s 는 로컬 모드에서 쓰이지 않는다 — 지금 이 레포를 그대로 깐다\n' "$REF"
fi
printf '  prefix %s\n' "$PREFIX"
is_dry && printf '  모드   --dry-run — 아무것도 바꾸지 않는다\n'
[ "$ASSUME_YES" = 1 ] && printf '  모드   --yes — 물음에 전부 yes\n'

[ "$REMOTE" = 1 ] && remote_fetch

check_deps
install_bin
install_shims
install_snippet
install_preset
install_skill
show_cron
summary

printf '\n끝.\n'
exit 0
