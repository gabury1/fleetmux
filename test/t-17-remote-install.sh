#!/usr/bin/env bash
# install.sh 원격 모드 — `curl | bash` 로 들어온 설치를 **네트워크 없이** 끝까지 돌린다.
#
# ⛔ 진짜 네트워크를 쓰지 않는다. PATH 맨 앞에 가짜 curl/wget 을 세우고, URL 을 $SRV 아래의
#    로컬 파일 경로로 펴서 그 파일을 준다. 없으면 404(rc 22)다. 요청된 URL 은 전부 로그에
#    받아 적어, "무엇을 받으러 갔나"(태그 API 를 봤나·main 으로 흘렀나)를 잰다.
# ⛔ 진짜 tmux 도 안 부른다. t-12 와 같은 모양의 가짜 tmux 를 쓰고, -V 말고 다른 인자로
#    불리면 LEAK 파일이 남는다 — 파일 끝에서 그게 비었는지 단언한다.
#
# 릴리스 자산은 `make dist` 로 **실제로 만들어** 쓴다(레포 사본에서). 그래서 이 파일은
# 릴리스 파이프라인 전체를 한 번에 잰다: make dist → 자산 두 개 → 설치기가 받아서 대조 → 설치.
#
# TT_INSTALL_SH 로 다른 install.sh 를 지목할 수 있다 — 단언에 이빨이 있는지 되돌린 사본으로
# 확인할 때 쓴다(예: SHA 대조를 뺀 사본으로 돌리면 아래 ④가 FAIL 로 뒤집혀야 한다).
set -u
. "$(dirname "$0")/lib.sh"

ORIGPATH="$PATH"
REPO=$(cd "$(dirname "$0")/.." && pwd -P) || exit 1
tt_test_sandbox

INST="${TT_INSTALL_SH:-$REPO/install.sh}"
SLUG='fleetmux-test/fleetmux'
TAG='v9.9.9'

export TMPDIR="$TTROOT/tmp"        # 설치기의 임시 디렉토리도 샌드박스 안에 잡히게 한다
mkdir -p "$TMPDIR"

CALLS="$TTROOT/tmux-calls.log"
LEAK="$TTROOT/tmux-LEAK.log"
NETLOG="$TTROOT/net.log"
SRV="$TTROOT/srv"

has() { case "$1" in *"$2"*) printf 'yes' ;; *) printf 'no' ;; esac; }
ex()  { if [ -e "$1" ]; then printf 'yes'; else printf 'no'; fi; }
cnt() { grep -c "$2" "$1" 2>/dev/null || true; }

# ── PATH 봉인 ────────────────────────────────────────────────────────────────
# 이 기계에 무엇이 깔려 있는지에 테스트가 기대면 안 된다. 필요한 것만 심링크한 디렉토리를
# 만들고 PATH 를 그것만으로 짠다. curl/wget 은 **여기 없다** — 가짜만 쓴다.
SEAL="$TTROOT/seal"
mkdir -p "$SEAL"
for c in sh bash env cat cp mv rm mkdir rmdir chmod ln cmp uname make awk sed grep tr cut \
         date ls dirname basename readlink sort head tail wc id touch find mktemp diff expr \
         tar gzip gunzip sha256sum shasum od printf; do
    p=$(PATH="$ORIGPATH" command -v "$c" 2>/dev/null) || continue
    ln -sf "$p" "$SEAL/$c"
done
for c in bash awk make cmp tar; do
    [ -e "$SEAL/$c" ] || { echo "  FAIL 봉인 PATH 에 $c 가 없다 — 이 기계에서는 이 테스트를 돌릴 수 없다"; exit 1; }
done
if [ ! -e "$SEAL/sha256sum" ] && [ ! -e "$SEAL/shasum" ]; then
    echo "  FAIL 이 기계에 sha256sum 도 shasum 도 없다 — 대조를 잴 수 없다"; exit 1
fi

# 해시 도구 없는 PATH — "대조할 도구가 없다" 갈래를 실제로 밟기 위해서다.
SEAL_NOSHA="$TTROOT/seal-nosha"
mkdir -p "$SEAL_NOSHA"
for f in "$SEAL"/*; do
    case "$(basename "$f")" in sha256sum|shasum) continue ;; esac
    ln -sf "$f" "$SEAL_NOSHA/$(basename "$f")"
done

# ── 가짜 tmux/fzf ────────────────────────────────────────────────────────────
STUB="$TTROOT/stub"
mkdir -p "$STUB"
{
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "tmux $*" >> "%s"\n' "$CALLS"
    printf 'if [ "${1:-}" = "-V" ]; then echo "tmux 3.5a"; exit 0; fi\n'
    printf 'printf "%%s\\n" "LEAK: tmux $*" >> "%s"\n' "$LEAK"
    printf 'exit 1\n'
} > "$STUB/tmux"
{
    printf '#!/usr/bin/env bash\n'
    printf 'if [ "${1:-}" = "--version" ]; then echo "0.65.2 (test)"; exit 0; fi\n'
    printf 'printf "%%s\\n" "LEAK: fzf $*" >> "%s"\n' "$LEAK"
    printf 'exit 1\n'
} > "$STUB/fzf"
chmod +x "$STUB/tmux" "$STUB/fzf"

# ── 가짜 서버 ────────────────────────────────────────────────────────────────
# URL → 파일 경로. https://a/b/c 는 $SRV/a/b/c 다. 없으면 404 처럼 rc≠0.
NET="$TTROOT/net"          # curl 만 있는 PATH 조각
NETW="$TTROOT/netw"        # wget 만 있는 PATH 조각
NONET="$TTROOT/nonet"      # 둘 다 없는 PATH 조각(빈 디렉토리)
mkdir -p "$NET" "$NETW" "$NONET" "$SRV"

{
    printf '#!/usr/bin/env bash\n'
    printf '# 가짜 curl — 네트워크를 쓰지 않는다. URL 을 로컬 파일로 편다.\n'
    printf 'url=""; out=""\n'
    printf 'while [ $# -gt 0 ]; do\n'
    printf '  case "$1" in\n'
    printf '    -o) out="$2"; shift ;;\n'
    printf '    --max-time) shift ;;\n'
    printf '    http://*|https://*) url="$1" ;;\n'
    printf '  esac\n'
    printf '  shift\n'
    printf 'done\n'
    printf 'printf "curl %%s\\n" "$url" >> "%s"\n' "$NETLOG"
    printf 'p=${url#https://}; p=${p#http://}\n'
    printf 'f="%s/$p"\n' "$SRV"
    printf 'if [ ! -f "$f" ]; then echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; fi\n'
    printf 'if [ -n "$out" ]; then cp "$f" "$out"; else cat "$f"; fi\n'
} > "$NET/curl"
{
    printf '#!/usr/bin/env bash\n'
    printf '# 가짜 wget — 같은 규칙. -O 로 받는다.\n'
    printf 'url=""; out=""\n'
    printf 'while [ $# -gt 0 ]; do\n'
    printf '  case "$1" in\n'
    printf '    -O) out="$2"; shift ;;\n'
    printf '    -T) shift ;;\n'
    printf '    http://*|https://*) url="$1" ;;\n'
    printf '  esac\n'
    printf '  shift\n'
    printf 'done\n'
    printf 'printf "wget %%s\\n" "$url" >> "%s"\n' "$NETLOG"
    printf 'p=${url#https://}; p=${p#http://}\n'
    printf 'f="%s/$p"\n' "$SRV"
    # 진짜 wget 은 404 에도 -O 파일을 만들어 놓는다. 그 껍데기를 그대로 흉내낸다 —
    # 설치기가 빈 파일을 "받았다"고 믿으면 여기서 걸려야 한다.
    printf 'if [ ! -f "$f" ]; then : > "$out"; echo "wget: 404" >&2; exit 8; fi\n'
    printf 'if [ -n "$out" ]; then cp "$f" "$out"; else cat "$f"; fi\n'
} > "$NETW/wget"
chmod +x "$NET/curl" "$NETW/wget"

# ── 릴리스 자산을 make dist 로 실제로 만든다 ────────────────────────────────
# 레포 사본에서 돌린다 — 진짜 레포에는 아무것도 안 쓴다.
REPOC="$TTROOT/repoc"
mkdir -p "$REPOC"
cp -R "$REPO/bin" "$REPO/libexec" "$REPO/src" "$REPO/skills" "$REPOC/"
cp "$REPO/Makefile" "$REPO/install.sh" "$REPO/README.md" "$REPO/LICENSE" "$REPOC/"
cp "$INST" "$REPOC/install.sh"
DIST="$TTROOT/dist"
DISTOUT=$(PATH="$SEAL" make -C "$REPOC" dist DISTDIR="$DIST" VERSION="$TAG" 2>&1) || DISTOUT="MAKE-FAILED
$DISTOUT"

assert_eq "$(ex "$DIST/fleetmux-$TAG.tar.gz")" "yes" "make dist 가 릴리스 tarball 을 만든다"
assert_eq "$(ex "$DIST/SHA256SUMS")" "yes" "make dist 가 SHA256SUMS 를 같이 만든다"
assert_eq "$(cnt "$DIST/SHA256SUMS" "fleetmux-$TAG.tar.gz")" "1" "SHA256SUMS 가 그 tarball 을 가리킨다"
assert_eq "$(has "$DISTOUT" 'MAKE-FAILED')" "no" "make dist 가 성공했다"

# 사람이 손으로 해시를 치지 않아도 되는지 — 만들어진 SHA256SUMS 가 진짜 해시와 같은가.
if [ -e "$SEAL/sha256sum" ]; then REALSHA=$(PATH="$SEAL" sha256sum "$DIST/fleetmux-$TAG.tar.gz" | awk '{print $1}')
else REALSHA=$(PATH="$SEAL" shasum -a 256 "$DIST/fleetmux-$TAG.tar.gz" | awk '{print $1}'); fi
assert_eq "$(awk '{print $1}' "$DIST/SHA256SUMS")" "$REALSHA" "SHA256SUMS 의 해시가 실제 파일의 해시와 같다"

# 아카이브 안에 설치에 필요한 것이 다 들었나 — 없으면 원격 설치가 반쪽이 된다.
TARLIST=$(PATH="$SEAL" tar -tzf "$DIST/fleetmux-$TAG.tar.gz")
for want in "fleetmux-$TAG/bin/fmux" "fleetmux-$TAG/libexec/claude" "fleetmux-$TAG/libexec/codex" \
            "fleetmux-$TAG/skills/fleetmux/SKILL.md"; do
    assert_eq "$(has "$TARLIST" "$want")" "yes" "아카이브에 $want 가 들어 있다"
done

# ── 가짜 릴리스를 서버에 올린다 ─────────────────────────────────────────────
API="$SRV/api.github.com/repos/$SLUG/releases"
DLD="$SRV/github.com/$SLUG/releases/download/$TAG"
mkdir -p "$API" "$DLD"
printf '{"url":"x","tag_name": "%s", "name":"%s","draft":false}\n' "$TAG" "$TAG" > "$API/latest"
cp "$DIST/fleetmux-$TAG.tar.gz" "$DLD/fleetmux-$TAG.tar.gz"
cp "$DIST/SHA256SUMS"           "$DLD/SHA256SUMS"

# 설치기를 레포 밖에 홀로 둔다 — 이게 `curl | bash` 가 만드는 상황이다(옆에 레포가 없다).
ALONE="$TTROOT/alone"
mkdir -p "$ALONE"
cp "$INST" "$ALONE/install.sh"

OUT=''; RC=0
run_remote() {   # $1=PATH 조각(네트워크), 나머지=install.sh 인자
    local net="$1"; shift
    RC=0
    OUT=$(PATH="$STUB:$net:$SEAL" FMUX_SLUG="$SLUG" bash "$ALONE/install.sh" "$@" < /dev/null 2>&1) || RC=$?
}
tmpd_of() { printf '%s\n' "$1" | sed -n 's/^  ok   임시 디렉토리: \([^ ]*\).*/\1/p' | head -1; }

# ── ① 모드 판별 ─────────────────────────────────────────────────────────────
: > "$NETLOG"
run_remote "$NET" --prefix "$TTROOT/p1" --preset safe
assert_eq "$RC" "0" "원격 설치가 rc 0 으로 끝난다"
assert_eq "$(has "$OUT" '모드   원격')" "yes" "무슨 모드인지 화면에 한 줄로 밝힌다"
assert_eq "$(has "$OUT" '레포가 없다')" "yes" "왜 원격인지 말한다"
assert_eq "$(ex "$TTROOT/p1/bin/fmux")" "yes" "가짜 HOME 쪽 prefix 에 fmux 가 깔린다"
assert_rc 0 test -x "$TTROOT/p1/bin/fmux"
assert_eq "$(readlink "$TTROOT/p1/bin/tt")" "fmux" "tt 심링크도 걸린다"
assert_eq "$(ex "$TTROOT/p1/libexec/tt/claude")" "yes" "훅 shim 도 깔린다"
assert_eq "$(ex "$XDG_CONFIG_HOME/fleetmux/tmux.conf")" "yes" "tmux 스니펫도 생긴다"
# 깔린 것이 아카이브 안의 그 바이트인가 — 대조한 것과 깔린 것이 같아야 대조가 뜻을 가진다
assert_rc 0 cmp -s "$REPOC/bin/fmux" "$TTROOT/p1/bin/fmux"

# 무엇을 받으러 갔나 — 기본은 최신 릴리스 태그다. main 으로 흐르지 않는다.
assert_eq "$(cnt "$NETLOG" 'api.github.com/repos/'"$SLUG"'/releases/latest')" "1" "기본은 최신 릴리스 태그를 물어본다"
assert_eq "$(cnt "$NETLOG" "releases/download/$TAG/fleetmux-$TAG.tar.gz")" "1" "그 태그의 릴리스 자산을 받는다"
assert_eq "$(cnt "$NETLOG" "releases/download/$TAG/SHA256SUMS")" "1" "SHA256SUMS 도 같이 받는다"
assert_eq "$(cnt "$NETLOG" 'main')" "0" "main 은 어디에서도 받지 않는다"
assert_eq "$(has "$OUT" "최신 릴리스 태그: $TAG")" "yes" "무슨 태그를 골랐는지 말한다"
assert_eq "$(has "$OUT" 'SHA256 일치')" "yes" "대조했다고 말한다"

# 임시 디렉토리는 성공해도 남지 않는다
T1=$(tmpd_of "$OUT")
assert_eq "$(has "$T1" 'fmux-install.')" "yes" "임시 디렉토리 경로를 화면에 밝힌다"
assert_eq "$(ex "$T1")" "no" "★성공해도 임시 디렉토리가 안 남는다"
assert_eq "$(has "$OUT" '임시 디렉토리를 지웠다')" "yes" "지웠다고 말한다"

# ── ②  `curl … | bash` 그 모양 그대로 ───────────────────────────────────────
# stdin 이 스크립트다 — 그래서 물을 수 없고, 물을 수 없으면 아무 동의도 가정하지 않는다.
# 레포가 없는 자리에서 돌린다(홈 디렉토리에서 한 줄 치는 것이 실제 모양이다).
ELSEWHERE="$TTROOT/elsewhere"
mkdir -p "$ELSEWHERE"
: > "$NETLOG"
RC=0
OUT=$(cd "$ELSEWHERE" && PATH="$STUB:$NET:$SEAL" FMUX_SLUG="$SLUG" \
        bash -s -- --prefix "$TTROOT/p2" --preset safe < "$ALONE/install.sh" 2>&1) || RC=$?
assert_eq "$RC" "0" "파이프로 들여보내도 rc 0"
assert_eq "$(has "$OUT" '모드   원격')" "yes" "파이프로 와도 원격으로 판별한다"
assert_eq "$(has "$OUT" "최신 릴리스 태그: $TAG")" "yes" "파이프 설치도 최신 태그를 고른다"
assert_eq "$(ex "$TTROOT/p2/bin/fmux")" "yes" "파이프 설치로도 fmux 가 깔린다"
assert_eq "$(ex "$HOME/.tmux.conf")" "no" "물을 수 없으니 남의 tmux 설정을 안 만든다"

# 거꾸로 — 클론 **안에서** 파이프로 돌리면 그 클론을 쓴다(로컬). 판별은 $0 이 아니라 파일이다.
: > "$NETLOG"
RC=0
OUT=$(cd "$REPOC" && PATH="$STUB:$NET:$SEAL" FMUX_SLUG="$SLUG" \
        bash -s -- --prefix "$TTROOT/p2b" --preset safe < "$ALONE/install.sh" 2>&1) || RC=$?
assert_eq "$(has "$OUT" '모드   로컬')" "yes" "레포 안에서 파이프로 돌리면 그 레포를 쓴다"
assert_eq "$(cnt "$NETLOG" '.')" "0" "그때는 네트워크를 안 쓴다"

# ── ③ --ref 로 지정하면 태그 API 를 안 본다 ────────────────────────────────
: > "$NETLOG"
run_remote "$NET" --ref "$TAG" --prefix "$TTROOT/p3" --preset safe
assert_eq "$RC" "0" "--ref 지정 설치는 rc 0"
assert_eq "$(cnt "$NETLOG" 'api.github.com')" "0" "--ref 를 주면 최신 태그를 물어보지 않는다"
assert_eq "$(has "$OUT" "--ref 로 받는다: $TAG")" "yes" "무엇을 받는지 말한다"
assert_eq "$(ex "$TTROOT/p3/bin/fmux")" "yes" "--ref 로도 깔린다"

# ── ④ SHA 가 다르면 멈춘다 ─────────────────────────────────────────────────
# 변조본을 만든다. **멀쩡히 풀리는 아카이브**여야 한다 — 깨진 파일이면 tar 가 먼저 죽어서
# "SHA 대조가 막았다"가 아니라 "어차피 안 풀렸다"가 되고, 그 그물에는 이빨이 없다.
# 그래서 진짜 공격처럼 파일 하나를 끼워 넣고 다시 압축한다.
BADTAG='v8.8.8'
BADD="$SRV/github.com/$SLUG/releases/download/$BADTAG"
mkdir -p "$BADD" "$TTROOT/tam"
PATH="$SEAL" tar -xzf "$DIST/fleetmux-$TAG.tar.gz" -C "$TTROOT/tam"
mv "$TTROOT/tam/fleetmux-$TAG" "$TTROOT/tam/fleetmux-$BADTAG"
printf '#!/bin/sh\n# 끼워넣은 파일\n' > "$TTROOT/tam/fleetmux-$BADTAG/EVIL.sh"
PATH="$SEAL" tar -czf "$TTROOT/tampered.tar.gz" -C "$TTROOT/tam" "fleetmux-$BADTAG"
assert_rc 0 env PATH="$SEAL" tar -tzf "$TTROOT/tampered.tar.gz"
cp "$TTROOT/tampered.tar.gz" "$BADD/fleetmux-$BADTAG.tar.gz"
{
    printf '%s  fleetmux-%s.tar.gz\n' "$REALSHA" "$BADTAG"      # ← 원본의 해시(=안 맞는다)
} > "$BADD/SHA256SUMS"

: > "$NETLOG"
run_remote "$NET" --ref "$BADTAG" --prefix "$TTROOT/p4" --preset safe
assert_eq "$RC" "1" "★SHA 가 다르면 멈춘다"
assert_eq "$(has "$OUT" 'SHA256 가 다르다')" "yes" "왜 멈췄는지 말한다"
assert_eq "$(has "$OUT" "$REALSHA")" "yes" "기대한 해시를 보여준다"
assert_eq "$(ex "$TTROOT/p4")" "no" "★변조본은 한 바이트도 안 깔린다"
T4=$(tmpd_of "$OUT")
assert_eq "$(ex "$T4")" "no" "★실패해도 임시 디렉토리가 안 남는다"

# 같은 자리에서 해시를 맞춰 놓으면 통과해야 한다 — 그래야 위 단언이 '항상 실패'가 아니다.
if [ -e "$SEAL/sha256sum" ]; then BADSHA=$(PATH="$SEAL" sha256sum "$TTROOT/tampered.tar.gz" | awk '{print $1}')
else BADSHA=$(PATH="$SEAL" shasum -a 256 "$TTROOT/tampered.tar.gz" | awk '{print $1}'); fi
printf '%s  fleetmux-%s.tar.gz\n' "$BADSHA" "$BADTAG" > "$BADD/SHA256SUMS"
run_remote "$NET" --ref "$BADTAG" --prefix "$TTROOT/p4b" --preset safe
assert_eq "$RC" "0" "해시가 맞으면 같은 아카이브가 통과한다(대조가 내용이 아니라 해시를 본다)"
assert_eq "$(ex "$TTROOT/p4b/bin/fmux")" "yes" "그때는 깔린다"

# SHA256SUMS 에 우리 파일 항목이 아예 없는 경우 — '대조했다'고 말하면 안 된다
printf '%s  something-else.tar.gz\n' "$BADSHA" > "$BADD/SHA256SUMS"
run_remote "$NET" --ref "$BADTAG" --prefix "$TTROOT/p4c" --preset safe
assert_eq "$RC" "1" "SHA256SUMS 에 그 파일 항목이 없으면 멈춘다"
assert_eq "$(has "$OUT" '항목이 없다')" "yes" "무엇이 없는지 말한다"
assert_eq "$(ex "$TTROOT/p4c")" "no" "그때도 아무것도 안 깐다"

# ── ⑤ SHA256SUMS 가 없는 릴리스 ────────────────────────────────────────────
NOSUM='v7.7.7'
NOSUMD="$SRV/github.com/$SLUG/releases/download/$NOSUM"
mkdir -p "$NOSUMD"
cp "$DIST/fleetmux-$TAG.tar.gz" "$NOSUMD/fleetmux-$NOSUM.tar.gz"      # SHA256SUMS 는 안 올린다

run_remote "$NET" --ref "$NOSUM" --prefix "$TTROOT/p5" --preset safe
assert_eq "$RC" "1" "★SHA256SUMS 가 없으면 (물을 수 없는 자리에서는) 멈춘다"
assert_eq "$(has "$OUT" 'SHA256SUMS 가 없다')" "yes" "없다고 말한다"
assert_eq "$(has "$OUT" '유일한 방어선')" "yes" "왜 그냥 못 넘어가는지 말한다"
assert_eq "$(ex "$TTROOT/p5")" "no" "무검증으로는 안 깐다"

run_remote "$NET" --yes --ref "$NOSUM" --prefix "$TTROOT/p5b" --preset safe
assert_eq "$RC" "1" "★--yes 는 무검증 설치를 승인하지 않는다"
assert_eq "$(has "$OUT" '--yes 로는 무검증 설치를 승인하지 않는다')" "yes" "--yes 를 이름으로 거절한다"
assert_eq "$(ex "$TTROOT/p5b")" "no" "--yes 여도 안 깐다"

# ── ⑥ 대조할 도구가 없는 기계 ──────────────────────────────────────────────
RC=0
OUT=$(PATH="$STUB:$NET:$SEAL_NOSHA" FMUX_SLUG="$SLUG" bash "$ALONE/install.sh" \
        --ref "$TAG" --prefix "$TTROOT/p6" --preset safe < /dev/null 2>&1) || RC=$?
assert_eq "$RC" "1" "★sha256sum·shasum 이 둘 다 없으면 (못 물으니) 멈춘다"
assert_eq "$(has "$OUT" 'shasum 도 없다')" "yes" "무슨 도구가 없는지 이름으로 말한다"
assert_eq "$(ex "$TTROOT/p6")" "no" "대조를 못 하면 안 깐다"
RC=0
OUT=$(PATH="$STUB:$NET:$SEAL_NOSHA" FMUX_SLUG="$SLUG" bash "$ALONE/install.sh" \
        --yes --ref "$TAG" --prefix "$TTROOT/p6b" --preset safe < /dev/null 2>&1) || RC=$?
assert_eq "$RC" "1" "도구가 없을 때 --yes 도 멈춘다"
assert_eq "$(ex "$TTROOT/p6b")" "no" "--yes 여도 안 깐다"

# ── ⑦ 태그를 못 알아내면 멈춘다 — main 으로 흐르지 않는다 ──────────────────
mv "$API/latest" "$API/latest.off"
: > "$NETLOG"
run_remote "$NET" --prefix "$TTROOT/p7" --preset safe
assert_eq "$RC" "1" "★최신 태그를 못 받으면 멈춘다"
assert_eq "$(has "$OUT" 'main 으로 대신 받지 않는다')" "yes" "main 으로 안 간다고 말한다"
assert_eq "$(has "$OUT" '--ref')" "yes" "대신 무엇을 하라고 알려준다"
assert_eq "$(cnt "$NETLOG" 'main')" "0" "★실제로 main 을 받으러 가지 않았다"
assert_eq "$(cnt "$NETLOG" 'releases/download')" "0" "아무 아카이브도 받지 않았다"
assert_eq "$(ex "$TTROOT/p7")" "no" "아무것도 안 깔린다"

# 태그 이름이 안 들어 있는 응답도 같은 판정이어야 한다(200 이지만 쓸모없는 답)
printf '{"message":"Not Found"}\n' > "$API/latest"
: > "$NETLOG"
run_remote "$NET" --prefix "$TTROOT/p7b" --preset safe
assert_eq "$RC" "1" "tag_name 이 없는 응답에도 멈춘다"
assert_eq "$(cnt "$NETLOG" 'releases/download')" "0" "그때도 아무것도 안 받는다"
printf '{"url":"x","tag_name": "%s", "name":"%s"}\n' "$TAG" "$TAG" > "$API/latest"

# ── ⑧ 받는 도구 — wget 폴백, 둘 다 없으면 멈춘다 ───────────────────────────
: > "$NETLOG"
run_remote "$NETW" --prefix "$TTROOT/p8" --preset safe
assert_eq "$RC" "0" "curl 이 없어도 wget 으로 받는다"
assert_eq "$(has "$OUT" 'wget 으로 받는다')" "yes" "무엇으로 받는지 말한다"
assert_eq "$(cnt "$NETLOG" '^wget ')" "3" "실제로 wget 이 세 번(태그·자산·SHA) 나갔다"
assert_eq "$(cnt "$NETLOG" '^curl ')" "0" "curl 은 안 썼다"
assert_eq "$(ex "$TTROOT/p8/bin/fmux")" "yes" "wget 경로로도 깔린다"

: > "$NETLOG"
run_remote "$NONET" --prefix "$TTROOT/p9" --preset safe
assert_eq "$RC" "1" "curl 도 wget 도 없으면 멈춘다"
assert_eq "$(has "$OUT" 'curl 도 wget 도 없다')" "yes" "둘 다 없다고 말한다"
assert_eq "$(has "$OUT" 'brew install curl')" "yes" "무엇을 깔라고 알려준다"
assert_eq "$(ex "$TTROOT/p9")" "no" "아무것도 안 깔린다"

# wget 이 404 에 남기는 빈 껍데기를 '받았다'고 믿지 않는다 — 없는 태그로 확인한다.
: > "$NETLOG"
run_remote "$NETW" --ref v0.0.0-none --prefix "$TTROOT/p9b" --preset safe
assert_eq "$RC" "1" "없는 태그면 멈춘다"
assert_eq "$(has "$OUT" '아카이브를 못 받았다')" "yes" "못 받았다고 말한다"
assert_eq "$(ex "$TTROOT/p9b")" "no" "빈 파일을 아카이브로 착각해 깔지 않는다"

# ── ⑨ 자리표시자 주소로는 안 나간다 ────────────────────────────────────────
: > "$NETLOG"
RC=0
OUT=$(PATH="$STUB:$NET:$SEAL" bash "$ALONE/install.sh" --prefix "$TTROOT/p10" < /dev/null 2>&1) || RC=$?
assert_eq "$RC" "1" "FMUX_SLUG 없이 원격으로 돌리면 멈춘다(레포가 아직 비공개다)"
assert_eq "$(has "$OUT" '공개 배포 주소가 없다')" "yes" "왜 못 받는지 말한다"
assert_eq "$(has "$OUT" 'README')" "yes" "공개되면 어디를 고치는지 말한다"
assert_eq "$(cnt "$NETLOG" 'OWNER')" "0" "자리표시자 URL 로 실제 요청을 보내지 않는다"

# ── ⑩ --dry-run — 받기는 받아도 사용자 파일은 하나도 안 바뀐다 ─────────────
: > "$NETLOG"
run_remote "$NET" --dry-run --prefix "$TTROOT/p11" --preset safe
assert_eq "$RC" "0" "원격 --dry-run 은 rc 0"
assert_eq "$(has "$OUT" 'dry  ')" "yes" "할 일을 dry 줄로 보여준다"
assert_eq "$(ex "$TTROOT/p11")" "no" "★dry-run 은 아무것도 안 깐다"
T11=$(tmpd_of "$OUT")
assert_eq "$(ex "$T11")" "no" "dry-run 이 받은 임시 디렉토리도 안 남는다"
assert_eq "$(has "$OUT" '임시 디렉토리 밖으로는 한 바이트도 안 나간다')" "yes" "왜 받았는지 밝힌다"

# ── ⑪ 로컬 모드 회귀 — 레포 안이면 예전 그대로다 ───────────────────────────
: > "$NETLOG"
RC=0
OUT=$(PATH="$STUB:$NET:$SEAL" bash "$REPOC/install.sh" --prefix "$TTROOT/p12" --preset safe \
        < /dev/null 2>&1) || RC=$?
assert_eq "$RC" "0" "로컬 모드 설치는 rc 0"
assert_eq "$(has "$OUT" '모드   로컬')" "yes" "로컬이라고 한 줄로 밝힌다"
assert_eq "$(has "$OUT" '모드   원격')" "no" "원격으로 오판하지 않는다"
assert_eq "$(cnt "$NETLOG" '.')" "0" "★로컬 모드는 네트워크를 한 번도 안 쓴다"
assert_eq "$(ex "$TTROOT/p12/bin/fmux")" "yes" "로컬 모드도 그대로 깔린다"
assert_eq "$(readlink "$TTROOT/p12/bin/tt")" "fmux" "tt 심링크도 그대로다"
assert_eq "$(has "$OUT" '0/8')" "no" "로컬 모드에는 0단계가 안 뜬다"

# 로컬 모드에서 --ref 는 무시되고, 무시한다고 말한다(조용히 삼키지 않는다)
RC=0
OUT=$(PATH="$STUB:$NET:$SEAL" bash "$REPOC/install.sh" --ref v1.2.3 --prefix "$TTROOT/p13" --preset safe \
        < /dev/null 2>&1) || RC=$?
assert_eq "$RC" "0" "로컬 모드에 --ref 를 줘도 rc 0"
assert_eq "$(has "$OUT" '로컬 모드에서 쓰이지 않는다')" "yes" "--ref 를 무시했다고 말한다"
assert_eq "$(cnt "$NETLOG" '.')" "0" "그때도 네트워크를 안 쓴다"

# ── ⑫ 문서·사용법 ──────────────────────────────────────────────────────────
USAGE=$(PATH="$SEAL" bash "$INST" --help 2>&1) || USAGE=''
assert_eq "$(has "$USAGE" '--ref')" "yes" "install.sh --help 가 --ref 를 안내한다"
assert_eq "$(has "$USAGE" 'curl -fsSL')" "yes" "--help 가 원격 한 줄도 보여준다"
RM=$(cat "$REPO/README.md")
assert_eq "$(has "$RM" 'curl -fsSL')" "yes" "README 가 한 줄 설치를 적는다"
assert_eq "$(has "$RM" '| bash')" "yes" "README 가 파이프 형태를 적는다"
assert_eq "$(has "$RM" '-o install.sh')" "yes" "README 가 받아서 읽고 실행하는 두 단계도 적는다"
assert_eq "$(has "$RM" 'less install.sh')" "yes" "그 두 단계에 눈으로 보는 절차가 들어 있다"
assert_eq "$(has "$RM" '--ref')" "yes" "README 가 --ref 를 적는다"
assert_eq "$(has "$RM" 'SHA256SUMS')" "yes" "README 가 SHA256SUMS 검증을 적는다"
assert_eq "$(has "$RM" 'make dist')" "yes" "README 가 릴리스 만드는 법을 적는다"
MK=$(cat "$REPO/Makefile")
assert_eq "$(has "$MK" 'dist:')" "yes" "Makefile 에 dist 타깃이 있다"
assert_eq "$(has "$MK" 'shasum -a 256')" "yes" "dist 가 맥의 해시 도구도 본다"
INSTSH=$(cat "$INST")
assert_eq "$(has "$INSTSH" 'shasum -a 256')" "yes" "설치기도 맥의 해시 도구를 본다"
assert_eq "$(has "$INSTSH" 'sha256sum')" "yes" "설치기가 리눅스의 해시 도구도 본다"

# ── ⑬ 진짜 tmux 가 샜나 ────────────────────────────────────────────────────
assert_eq "$(ex "$LEAK")" "no" "가짜 tmux/fzf 가 -V 말고 다른 인자로 불린 적이 없다"
assert_rc 0 test -s "$CALLS"

tt_test_done
