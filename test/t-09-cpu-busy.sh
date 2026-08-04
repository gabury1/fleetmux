#!/usr/bin/env bash
# CPU 델타 기반 작업중 판정 — tt_cpu_read / tt_cpu_cs_ps / tt_cpu_sample / tt_cpu_busy.
#
# 왜 이 테스트가 있나: 화면 판정(t-08)은 렌더링 산출물을 읽는 일이라 TUI 문구가 바뀌면 조용히
# 깨진다. CPU 델타는 그 보험인데, 이쪽이 잘못 "아니다"라고 답하면 t-08 이 막으려던 바로 그 사고
# (진짜 일하는 세션의 ✻ 삭제)가 다시 난다. 그래서 여기서 가장 크게 잰 것은 **rc 2(판정불가)와
# rc 1(작업중 아님)의 구분**이다 — 모름을 아님으로 접는 순간 ✻ 가 또 사라진다.
#
# ⛔ tmux 를 부르지 않는다. 실제 프로세스에도 의존하지 않는다:
#    /proc 은 TT_PROC 로 가짜 디렉토리를 주입하고, macOS 폴백은 ps 를 셸 함수로 가려 재현한다.
#    그래서 이 테스트는 맥에서도, CPU 가 놀고 있든 타고 있든 똑같은 답을 낸다.
set -u
. "$(dirname "$0")/lib.sh"
tt_test_sandbox

# ── 산출물에서 판정부만 떼어온다 ─────────────────────────────────────────────
# bin/fmux 를 통째로 source 하면 진입점(fzf 팝업)까지 돈다. 필요한 조각만 뽑아 eval 한다.
# src 를 직접 읽으면 "고쳤는데 안 빌드한" 상태를 통과시키므로 반드시 bin/fmux 에서 뽑는다.
eval "$(sed -n '/^TT_CPU_[A-Z_]*=/p' "$TTBIN")"
for fn in tt_cpu_cs_ps tt_cpu_read tt_cpu_sample tt_cpu_busy; do
    eval "$(awk -v n="$fn" 'index($0, n "() {") == 1 { f = 1 } f { print } f && /^\}$/ { exit }' "$TTBIN")"
    TT_RUN=$((TT_RUN + 1))
    if [ "$(type -t "$fn" 2>/dev/null)" = function ]; then
        printf '  ok   bin/fmux 에서 %s 를 떼어왔다\n' "$fn"
    else
        TT_FAIL=$((TT_FAIL + 1))
        printf '  FAIL bin/fmux 에서 %s 를 못 떼어왔다 — 추출 awk 가 함수 모양을 못 따라간다\n' "$fn"
    fi
done

# 상수가 실제로 실려 있는지 — 하나라도 비면 아래 산술이 통째로 무의미해진다
assert_eq "$TT_CPU_BUSY:$TT_CPU_MINWIN:$TT_CPU_MINWIN_COARSE:$TT_CPU_MAXWIN:$TT_CPU_ROTATE" \
    "6:3:20:60:3" '임계값 상수 다섯 개가 산출물에 실측값 그대로 실려 있다'

STATE="$HOME/.cache/tt"; mkdir -p "$STATE"
PROC="$TTROOT/proc"; export TT_PROC="$PROC"

# ── 가짜 /proc ───────────────────────────────────────────────────────────────
# comm 에 공백과 ') ' 를 일부러 넣는다 — 오른쪽 최장매치(##*') ')가 아니면 여기서 깨진다.
# 자른 나머지의 1번째가 state 이므로 utime=arr[11], stime=arr[12] 자리에 값이 온다.
fake_proc() {                # fake_proc <pid> <utime> <stime>
    mkdir -p "$PROC/$1"
    printf '%s (cl) aude (x)) S 1 %s %s 0 -1 4194304 111 222 0 0 %s %s 0 0 20 0 12 0 999 0 0\n' \
        "$1" "$1" "$1" "$2" "$3" > "$PROC/$1/stat"
}
snap() { printf '%s\n' "$*" > "$STATE/cpu-s1"; }     # 스냅샷 한 줄 심기
rc_of() { local r=0; "$@" >/dev/null 2>&1 || r=$?; printf '%s' "$r"; }

NOW=1800000000

# ── ① tt_cpu_read — /proc 파싱 ──────────────────────────────────────────────
fake_proc 4242 1000 234
TT_CPU_CS=""; TT_CPU_Q=""
assert_eq "$(rc_of tt_cpu_read 4242)" "0" 'tt_cpu_read: 가짜 /proc 을 읽는다'
tt_cpu_read 4242
assert_eq "$TT_CPU_CS" "1234" 'utime+stime 을 더한다(cutime/cstime 은 절대 안 더한다 — 회수 스파이크)'
assert_eq "$TT_CPU_Q" "1" '/proc 분해능은 1cs(USER_HZ=100 고정)'
assert_eq "$(rc_of tt_cpu_read 0)" "1" 'pid 0 은 못 읽음'
assert_eq "$(rc_of tt_cpu_read abc)" "1" 'pid 가 숫자가 아니면 못 읽음'
printf 'garbage without parens\n' > "$PROC/4242/stat"
assert_eq "$(rc_of tt_cpu_read 4242)" "1" '/proc stat 형식이 아니면 못 읽음(옛 값을 남기지 않는다)'
fake_proc 4242 1000 234

# ── ② tt_cpu_cs_ps — macOS/BSD 폴백 파서 ────────────────────────────────────
# 실제 ps 를 부르지 않도록 셸 함수로 가린다. 함수는 같은 셸에서 외부 명령보다 먼저 잡힌다.
PS_OUT=""; PS_RC=0
ps() { [ "$PS_RC" = 0 ] || return "$PS_RC"; printf '%s\n' "$PS_OUT"; }
ps_cs() { PS_OUT="$1"; PS_RC=0; TT_CPU_CS=""; tt_cpu_cs_ps 1 >/dev/null 2>&1 || true; printf '%s' "$TT_CPU_CS"; }
assert_eq "$(ps_cs '  0:44.00')" "4400" 'Darwin MM:SS.cc'
assert_eq "$(ps_cs '00:07:48')" "46800" '리눅스 ps 의 HH:MM:SS(초 단위) — 실측 대조값'
assert_eq "$(ps_cs '1-02:03:04.5')" "9378450" 'DD-HH:MM:SS.c — 하루 넘게 돈 세션'
assert_eq "$(ps_cs '0:08.09')" "809" '08·09 를 8진수로 읽지 않는다(10# 접두사가 없으면 즉사)'
PS_OUT="1:00.00"; PS_RC=0; tt_cpu_cs_ps 1 >/dev/null 2>&1 || true
assert_eq "$TT_CPU_Q" "1" '소수점이 있으면 분해능 1cs — 맥의 정상 경로'
PS_OUT="00:07:48"; PS_RC=0; tt_cpu_cs_ps 1 >/dev/null 2>&1 || true
assert_eq "$TT_CPU_Q" "100" '소수점이 없으면 분해능 100cs → 호출부가 최소 창을 20초로 늘린다'
PS_RC=1
assert_eq "$(rc_of tt_cpu_cs_ps 1)" "1" 'ps 가 실패하면 못 읽음'
PS_OUT=""; PS_RC=0
assert_eq "$(rc_of tt_cpu_cs_ps 1)" "1" 'ps 가 빈 줄을 주면 못 읽음(파이프 rc 0 에 속지 않는다)'
PS_RC=1

# ── ③ tt_cpu_busy — 판정 ────────────────────────────────────────────────────
# 3값 rc 가 이 설계의 핵심이다: 0=작업중 / 1=아님 / 2=판정불가.
rm -f "$STATE/cpu-s1"
assert_eq "$(rc_of tt_cpu_busy s1 4242 "$NOW")" "2" \
    '★스냅샷이 없는 첫 호출(웜업)은 판정불가다 — 유휴로 접으면 ✻ 가 사라진다'
assert_eq "$(rc_of tt_cpu_busy '' 4242 "$NOW")" "2" 'sid 가 비면 판정불가'
assert_eq "$(rc_of tt_cpu_busy s1 0 "$NOW")" "2" 'pid 를 모르면(훅이 부모 체인 등반 실패) 판정불가'

# 임계 위/아래 — 창 5초, 임계 6 cs/s → 경계는 델타 30
fake_proc 4242 1000 234                                  # cs = 1234
snap 4242 $((NOW - 5)) 1194 0 0                          # Δ40 / 5s = 8.0 cs/s
assert_eq "$(rc_of tt_cpu_busy s1 4242 "$NOW")" "0" '임계 위(8.0 cs/s): 작업중'
snap 4242 $((NOW - 5)) 1214 0 0                          # Δ20 / 5s = 4.0 cs/s
assert_eq "$(rc_of tt_cpu_busy s1 4242 "$NOW")" "1" '임계 아래(4.0 cs/s): 작업중 아님 — 유휴 실측 최댓값 구간'
snap 4242 $((NOW - 5)) 1204 0 0                          # Δ30 / 5s = 정확히 6.0
assert_eq "$(rc_of tt_cpu_busy s1 4242 "$NOW")" "0" '경계값 6.0 cs/s 는 포함(>=)'
snap 4242 $((NOW - 5)) $((1204 + 1)) 0 0                 # Δ29 → 5.8
assert_eq "$(rc_of tt_cpu_busy s1 4242 "$NOW")" "1" '경계 바로 아래는 제외'

# 창 길이 — 실측상 1~2초 창은 작업중과 유휴가 겹친다. 겹치는 구간은 판정하면 안 된다.
snap 4242 $((NOW - 2)) 0 0 0                             # Δ1234 / 2s = 617 cs/s 인데도
assert_eq "$(rc_of tt_cpu_busy s1 4242 "$NOW")" "2" \
    '★창이 MINWIN(3초) 미만이면 델타가 아무리 커도 판정불가(1~2초 창은 유휴와 겹친다)'
snap 4242 $((NOW - 3)) 1216 0 0                          # Δ18 / 3s = 6.0
assert_eq "$(rc_of tt_cpu_busy s1 4242 "$NOW")" "0" 'MINWIN 정확히 3초면 판정한다'
snap 4242 $((NOW - 61)) 0 0 0                            # 아주 큰 델타지만 창이 61초
assert_eq "$(rc_of tt_cpu_busy s1 4242 "$NOW")" "2" \
    '★창이 MAXWIN(60초)을 넘으면 판정불가 — 긴 창은 희석돼 박제를 되살리는 흉기가 된다'
snap 4242 $((NOW + 10)) 1234 0 0                         # 시계가 뒤로 점프(NTP·서스펜드)
assert_eq "$(rc_of tt_cpu_busy s1 4242 "$NOW")" "2" '창이 음수면 판정불가(NTP 점프·서스펜드/리줌)'

# 표본 둘 — 최신이 너무 어리면 이전 것으로 창을 넓힌다. 이게 5초 갱신 주기와 3초 하한의 충돌을 푼다.
snap 4242 $((NOW - 1)) 1230 $((NOW - 6)) 1194            # 최신 1초(짧다) / 이전 6초 Δ40 = 6.7
assert_eq "$(rc_of tt_cpu_busy s1 4242 "$NOW")" "0" \
    '★최신 표본이 MINWIN 미만이면 이전 표본으로 창을 넓혀 판정한다(표본이 둘인 이유)'
snap 4242 $((NOW - 1)) 1230 $((NOW - 6)) 1214            # 이전 6초 Δ20 = 3.3
assert_eq "$(rc_of tt_cpu_busy s1 4242 "$NOW")" "1" '이전 표본으로도 임계 아래면 작업중 아님'
snap 4242 $((NOW - 1)) 1230 0 0                          # 이전 표본 없음
assert_eq "$(rc_of tt_cpu_busy s1 4242 "$NOW")" "2" '이전 표본이 없고 최신이 너무 어리면 판정불가'

# 자기 무효화 — 파일이 썩어도 옛 값으로 오판하지 않는다
snap 9999 $((NOW - 5)) 0 0 0
assert_eq "$(rc_of tt_cpu_busy s1 4242 "$NOW")" "2" '★pid 불일치(재부팅·재기동으로 번호 재사용) → 스냅샷 폐기'
snap 4242 $((NOW - 5)) 99999 0 0                         # 카운터가 뒤로 갔다
assert_eq "$(rc_of tt_cpu_busy s1 4242 "$NOW")" "2" '델타가 음수면(카운터 리셋) 판정불가'
snap 4242 abc 1194 0 0
assert_eq "$(rc_of tt_cpu_busy s1 4242 "$NOW")" "2" '썩은 줄은 판정불가(산술 오류로 목록을 죽이지 않는다)'
printf '' > "$STATE/cpu-s1"
assert_eq "$(rc_of tt_cpu_busy s1 4242 "$NOW")" "2" '빈 파일도 판정불가'

# 프로세스가 죽었을 때 — /proc 엔트리가 사라지고 ps 도 실패한다
snap 4242 $((NOW - 5)) 0 0 0                             # 델타가 아무리 커야 할 상황이어도
rm -rf "$PROC/4242"
assert_eq "$(rc_of tt_cpu_busy s1 4242 "$NOW")" "2" \
    '★프로세스가 죽으면(/proc 없음 + ps 실패) 판정불가 → 호출부는 화면 판정으로 내려간다'
fake_proc 4242 1000 234

# 분해능이 거칠면(초 단위 ps) 최소 창이 20초로 올라간다 — 양자화 오탐 차단
# /proc 을 치워 ps 경로로 떨어뜨리고, ps 가 소수점 없는 초 단위를 주게 한다.
rm -rf "$PROC/4242"
PS_OUT="00:00:12"; PS_RC=0                               # 1200 cs, 분해능 100cs
snap 4242 $((NOW - 5)) 1100 0 0                          # Δ100 / 5s = 20 cs/s — 눈금 하나가 만든 값
assert_eq "$(rc_of tt_cpu_busy s1 4242 "$NOW")" "2" \
    '★분해능 1초일 때 5초 창은 판정불가 — 유휴가 눈금 하나 넘기면 33 cs/s 로 읽혀 오탐이 난다'
snap 4242 $((NOW - 25)) 1100 0 0                         # Δ100 / 25s = 4.0 cs/s
assert_eq "$(rc_of tt_cpu_busy s1 4242 "$NOW")" "1" '분해능 1초라도 창이 20초를 넘으면 판정한다'
snap 4242 $((NOW - 25)) 1000 0 0                         # Δ200 / 25s = 8.0 cs/s
assert_eq "$(rc_of tt_cpu_busy s1 4242 "$NOW")" "0" '거친 분해능에서도 임계 위면 작업중'
PS_RC=1
fake_proc 4242 1000 234

# ── ④ tt_cpu_sample — 회전 ──────────────────────────────────────────────────
rm -f "$STATE/cpu-s1"
tt_cpu_sample s1 4242 "$NOW"
assert_eq "$(cat "$STATE/cpu-s1")" "4242 $NOW 1234 0 0" '첫 표본: 이전 자리는 0 0'
# ROTATE(3초) 안에 다시 부르면 파일을 아예 안 건드린다 — 팝업 연타로 창이 0초로 짜부라지지 않게
fake_proc 4242 2000 234
tt_cpu_sample s1 4242 $((NOW + 2))
assert_eq "$(cat "$STATE/cpu-s1")" "4242 $NOW 1234 0 0" '★ROTATE 안에 다시 불리면 파일 미접촉(창이 0초로 짜부라지지 않게)'
tt_cpu_sample s1 4242 $((NOW + 3))
assert_eq "$(cat "$STATE/cpu-s1")" "4242 $((NOW + 3)) 2234 $NOW 1234" 'ROTATE 경과 후: 옛 표본이 이전 자리로 밀린다'
# ★시계 역행 동결 — 회복 경로가 없는 유일한 자리라 여기서 가장 크게 잰다.
#   파일에 미래 시각이 박히면(NTP 보정·수동 시각 변경·서스펜드) now-ts1 이 음수가 되고,
#   음수는 `-lt ROTATE` 가 **영원히 참**이라 샘플러가 매번 즉시 return 한다 → 파일이 다시는
#   안 갱신되고, tt_cpu_busy 는 창이 음수라 계속 rc 2 → CPU 델타 판정이 통째로 죽는다.
#   가드는 "음수면 옛 표본을 버리고 지금 값으로 갈아엎는다" 이다.
rm -f "$STATE/cpu-s1"
fake_proc 4242 1000 234                                  # cs = 1234
snap 4242 $((NOW + 3600)) 9999 $((NOW + 3500)) 8888      # 한 시간 미래가 박혔다
tt_cpu_sample s1 4242 "$NOW"
assert_eq "$(cat "$STATE/cpu-s1")" "4242 $NOW 1234 0 0" \
    '★시계 역행(미래 시각이 박힘)이면 샘플러가 동결되지 않고 지금 값으로 갈아엎는다'
assert_eq "$(rc_of tt_cpu_busy s1 4242 $((NOW + 5)))" "1" \
    '★갈아엎은 표본으로 즉시 판정이 선다 — 동결이면 미래 시각이 그대로 남아 영원히 rc 2 다'
fake_proc 4242 1100 234                                  # +100cs
tt_cpu_sample s1 4242 $((NOW + 5))                       # ROTATE(3s) 경과 → 회전한다
assert_eq "$(cat "$STATE/cpu-s1")" "4242 $((NOW + 5)) 1334 $NOW 1234" \
    '★역행 다음 틱에는 정상 회전이 돌아온다(동결이면 여기서 파일이 그대로다)'
fake_proc 4242 1500 234                                  # 다시 +400cs
assert_eq "$(rc_of tt_cpu_busy s1 4242 $((NOW + 10)))" "0" \
    '★그리고 작업중 판정까지 돌아온다 — 400cs/5s = 80 cs/s'

# pid 가 바뀌면 옛 표본을 물려주지 않는다
rm -f "$STATE/cpu-s1"
fake_proc 4242 1000 234
tt_cpu_sample s1 4242 "$NOW"
fake_proc 4242 2000 234
tt_cpu_sample s1 4242 $((NOW + 3))
fake_proc 777 50 0
tt_cpu_sample s1 777 $((NOW + 10))
assert_eq "$(cat "$STATE/cpu-s1")" "777 $((NOW + 10)) 50 0 0" '★pid 가 바뀌면 옛 표본을 물려주지 않는다(카운터 리셋 오판 차단)'
# 못 읽는 pid 로는 파일을 망가뜨리지 않는다
tt_cpu_sample s1 4444 $((NOW + 20))
assert_eq "$(cat "$STATE/cpu-s1")" "777 $((NOW + 10)) 50 0 0" '카운터를 못 읽으면 기존 파일을 건드리지 않는다'
assert_eq "$(ls "$STATE" | grep -c '^cpu-s1\.' || true)" "0" 'tmp 파일이 남지 않는다(tmp+mv 원자적 쓰기)'
# 샘플 → 판정 왕복: 심어놓은 값 없이 두 번의 호출만으로 판정이 선다
rm -f "$STATE/cpu-s1"
fake_proc 555 0 0
tt_cpu_sample s1 555 "$NOW"
fake_proc 555 100 0                                       # 5초에 100cs = 20 cs/s
assert_eq "$(rc_of tt_cpu_busy s1 555 $((NOW + 5)))" "0" '샘플→판정 왕복: 표본을 남기고 다음 호출에서 델타가 선다'

tt_test_done
