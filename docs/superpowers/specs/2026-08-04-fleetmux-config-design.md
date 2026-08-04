# fleetmux 설정 시스템 — 설계

작성 2026-08-04 · 상태: 리뷰 대기

## 배경

fmux 는 지금까지 한 사람의 기계에서만 돌았다. 그래서 취향이 곧 기본값이었다 — rc 자동복구는
항상 켜져 있고, cron 은 1분마다 스냅샷을 찍고, "최근"은 6시간이고, 강조색은 73번이다.

공개 배포가 결정되면서 이 전제가 깨진다. 특히 **rc 자동복구는 남의 세션에 키를 입력하는
기능**이다. 처음 보는 사람이 이걸 못 끄는 도구를 설치할 이유가 없다.

## 목표

- 켜고 끄기: rc 자동복구, cron 스냅샷, 부팅 자동복원
- 튜닝: 최근 임계, ✓ 배지 유지, 강조색, 로그 회전 크기
- 단축키 재매핑: 팝업 내부 키 전부 + 팝업 소환키
- 설정을 **팝업 안에서** 바꿀 수 있을 것 (`tt` 를 벗어나지 않는다)
- 떠날 때(터미널 닫힘·detach·세션 종료) 함대를 한 번 더 기록할 것

## 비목표 (YAGNI)

- 프로젝트별·세션별 설정 — 머신 하나로 충분하다. 탐색 규칙과 우선순위만 복잡해진다.
- 설정 동기화·프로파일·테마 팩
- 훅 shim(`libexec/tt/claude`) on/off — 그건 설치 시점의 선택이고, 지우면 개입이 사라진다.

## 왜 환경변수만으로는 안 되는가

코드에는 이미 `${TT_LOG_MAX:-…}` 같은 관례가 있다. 그러나 정작 끄고 싶은 두 기능
(rc 자동복구·스냅샷)은 **cron 에서 돈다.** cron 은 로그인 셸을 거치지 않아 `~/.bashrc` 의
`export TT_RC=0` 을 영영 보지 못한다. 훅도 마찬가지로 에이전트 프로세스의 환경을 물려받을 뿐이다.

→ 설정은 **파일**이어야 한다. 환경변수는 그 위에 얹는 일회성 덮어쓰기로만 남긴다.

## 설계

### 1. 저장소

```
${XDG_CONFIG_HOME:-$HOME/.config}/fleetmux/config
```

```ini
# fleetmux config — tt config set <key> <value>
rc=off
recent_hours=12
key_new=ctrl-t
```

- 한 줄 `key=value`, `#` 주석, 빈 줄 허용
- **`source` 하지 않는다.** 화이트리스트 파서로 읽는다:
  줄이 `^[a-z_][a-z0-9_]*=[0-9A-Za-z_./:+-]*$` 를 만족하고 **키가 알려진 목록에 있을 때만** 채택.
  나머지는 무시하고 stderr 에 한 줄 경고.
  이유: 이 파일은 훅이 이벤트마다, cron 이 1분마다 읽는 경로다. `source` 라면 오타 한 줄이
  함대 관제 전체를 조용히 죽인다. 신뢰 경계를 파서 하나로 좁힌다.
- 읽기는 매 진입점 시작 시 1회(`tt_conf_load`). 파일은 열 줄 미만이라 캐시하지 않는다.

### 2. 우선순위

```
환경변수  >  설정 파일  >  코드 기본값
```

환경변수는 일회성 실험용(`TT_RC=0 tt --cron`). 기존 `TT_LOG_MAX`·`TT_BOOT_NETWAIT`·
`TT_MANIFEST` 는 그대로 살린다(하위호환).

### 3. 키 목록 v1

| 키 | 기본 | env | 끄면/바꾸면 |
|---|---|---|---|
| `rc` | `on` | `TT_RC` | rc 자동복구 단계를 통째로 건너뛴다. `⊘` 배지도 계산하지 않는다 |
| `snapshot` | `on` | `TT_SNAPSHOT` | `--cron` 이 매니페스트를 기록하지 않는다 |
| `snapshot_on_exit` | `on` | `TT_SNAPSHOT_ON_EXIT` | 떠날 때(detach·세션 닫힘) 기록하지 않는다 |
| `boot_restore` | `on` | `TT_BOOT_RESTORE` | `--boot-restore` 가 즉시 return |
| `recent_hours` | `6` | `TT_RECENT_HOURS` | 이름을 굵게 쓰는 기준 시간 |
| `unseen_minutes` | `10` | `TT_UNSEEN_MINUTES` | 상태바 `✓name` 유지 시간 |
| `accent` | `73` | `TT_ACCENT` | 256색 번호(도구 세션·헤더 강조) |
| `log_max` | `1048576` | `TT_LOG_MAX` | hook.log 회전 임계 (기존 변수 흡수) |

`on`/`off` 는 `1`/`0`, `true`/`false` 도 받는다. 그 외 값은 `set` 이 거부한다.

### 4. 단축키

| 키 | 기본 | 동작 |
|---|---|---|
| `key_new` | `ctrl-n` | 새 세션 |
| `key_rename` | `ctrl-e` | 이름 변경 |
| `key_kill` | `ctrl-x` | 세션 종료 |
| `key_reload` | `ctrl-r` | 목록 갱신 |
| `key_detach` | `ctrl-d` | tmux 탈출 |
| `key_broadcast` | `ctrl-b` | 팝업 유지 브로드캐스트 |
| `key_help` | `?` | 도움말 |
| `key_settings` | `ctrl-o` | 설정 화면 ("options") |
| `key_summon` | `F` | 팝업 소환 — prefix 뒤 (아래 6a·6절) |
| `key_summon_fast` | (비어 있음) | 무prefix 소환키 목록 (아래 6b절) |

값 문법은 **fzf 키 이름을 그대로 쓴다** (`ctrl-n`, `alt-x`, `f2`, `btab`). 새 문법을 만들지 않으면
fzf 문서가 그대로 우리 문서가 된다. `key_summon`·`key_summon_fast` 둘만 tmux 키 문법
(`F`, `M-Left`, `C-Left`, `M-b`)이다 — 그 둘은 fzf 가 아니라 tmux 가 받는 키다.

**예약**: `esc`·`left`(닫기)·`enter`(진입)는 재매핑 금지. 잘못 밟아도 나갈 수 있는 문 하나는
항상 열어둔다.

**충돌**: `set` 이 다른 액션과 같은 키를 거부한다(어떤 키와 부딪혔는지 출력).

**검증**: 로드 시 fzf 가 아는 키 이름인지 화이트리스트로 확인한다
(`ctrl-[a-z]`, `alt-[a-z0-9]`, `f1`–`f12`, `tab`/`btab`/`home`/`end`/`pgup`/`pgdn`/`del`/`ins`,
방향키, `?` 같은 단일 출력가능문자). 모르는 이름이면 **그 키만** 기본값으로 되돌리고 경고한다.

**최후 방어**: 검증을 통과한 조합이라도 fzf 가 기동에 실패할 수 있다(rc≠0, 즉시 종료).
이 경우 기본 바인딩으로 한 번 더 띄우고 "설정 키 때문에 기본값으로 떴다"고 알린다.
관제탑이 안 뜨는 상태가 가장 나쁜 실패다.

### 5. CLI

```
tt config                 # 전체 — 값 + 출처(default|file|env)
tt config get <key>
tt config set <key> <val> # 검증 → tmp 파일 → mv (원자적), flock 은 매니페스트와 같은 패턴
tt config unset <key>     # 파일에서 줄 제거 → 기본값으로 복귀
tt config path            # 설정 파일 경로 출력
```

잘못된 키·값은 rc 1 과 허용 범위를 출력한다. `set` 은 사람이 손편집한 주석·순서를 보존한다
(있는 줄은 교체, 없으면 append).

### 6a. 소환키 기본값 — 왜 prefix 인가

관용 조사(2026-08-04): tmux 세션 매니저 플러그인은 **예외 없이 `prefix + 한 글자`** 를 기본으로 쓴다.

| 도구 | 기본 |
|---|---|
| tmux-sessionx | `prefix + O` (무prefix는 `@sessionx-prefix off` 로 따로) |
| tmux-fzf | `prefix + F` |
| sesh / t-smart | `prefix + T` |
| tmux-session-wizard | `prefix + T` |
| tmux-fzf-session-switch | `prefix + C-f` |
| tmux-sessionist | `prefix + g` 외 |

무prefix 한 방 키를 **기본값**으로 두는 세션 매니저는 찾지 못했다. 이유는 플랫폼별 실측으로 분명하다:

| 키 | Linux | macOS | Windows(WSL2+WT) |
|---|---|---|---|
| `M-Left` (`ESC[1;3D`) | ✅ | ❌ Ghostty·Terminal.app 이 Option+← 를 `ESC b` 로 보냄 | ❌ WT 가 Alt+화살표를 pane 이동으로 먼저 먹음 |
| `M-b` (`ESC b`) | ✅ | ✅ **macOS 의 Option+← 는 여기로 온다** | ✅ |
| `C-Left` | ✅ | ⚠️ Mission Control 스페이스 전환이 먼저 먹을 수 있음 | ✅ |
| `prefix + F` | ✅ | ✅ | ✅ |

**macOS 의 Option+← 는 `M-b` 다.** Ghostty 는 `macos-option-as-alt=true` 에서도 `ESC b` 를 보낸다
(Terminal.app 호환 의도, ghostty#7131·discussion#7740). cmux 는 libghostty 기반이라 같다.
따라서 맥에서는 **Option+← 와 Alt+b 를 구분할 수 없다** — 이 키를 소환에 쓰면 readline
`backward-word` 를 잃는 것은 선택이 아니라 필연이다. README 에 그대로 적는다.

기본값은 `prefix + F`(fleet). tmux 기본 바인딩에서 대문자 `F` 는 비어 있다
(`f`=find-window, `Space`=next-layout 은 살아 있으므로 쓰지 않는다).

### 6b. 빠른 키 — 값이 아니라 목록

물리 키 하나가 터미널마다 다른 바이트로 도착한다. 그래서 `key_summon_fast` 는 공백으로 나눈 목록이다.

| 키 | 기본 | 뜻 |
|---|---|---|
| `key_summon` | `F` | prefix 뒤 한 글자. 보증선 |
| `key_summon_fast` | (비어 있음) | 무prefix 키 목록. 예: `C-Left M-Left M-b` |

install.sh 프리셋:

| 프리셋 | `key_summon_fast` | 대상 |
|---|---|---|
| safe | (비움) | 기본. 첫 실행이 반드시 성공한다 |
| mac | `M-b` | Ghostty·cmux·Terminal.app 에서 Option+← |
| linux | `C-Left M-Left` | 리눅스 로컬 터미널 |
| wsl | `C-Left` | Windows Terminal (Alt+화살표는 WT 가 먹는다) |

### 6. 팝업 소환키 — 전용 스니펫 파일

fmux 는 `~/.tmux.conf` 를 편집하지 않는다. 대신 자기 파일을 소유한다:

```
~/.config/fleetmux/tmux.conf     ← fmux 가 생성·소유. 사용자가 손대지 않는다
```

사용자 `.tmux.conf` 에는 설치 시 한 줄만 들어간다:

```tmux
source-file ~/.config/fleetmux/tmux.conf
```

```tmux
# 생성 예 — key_summon=F, key_summon_fast="C-Left M-b"
bind    F      display-popup -E -w 85% -h 75% "tt --from '#S'"
bind -n C-Left display-popup -E -w 85% -h 75% "tt --from '#S'"
bind -n M-b    display-popup -E -w 85% -h 75% "tt --from '#S'"
```

`tt config set key_summon_fast "C-Left M-b"` 는 자기 파일만 다시 쓰고, tmux 안이면
`tmux source-file` 로 즉시 반영한다. 목록에서 빠진 키는 `unbind` 도 함께 낸다 —
안 그러면 지운 바인딩이 서버가 죽을 때까지 남는다.

shim 철학과 같다 — **한 줄만 빌리고, 지우면 흔적이 사라진다.**

### 7. 팝업 설정 화면

- 진입 둘: 어디서나 `key_settings`(기본 `ctrl-o`), 목록 하단 `⚙ settings` 항목
- 화면은 fzf 재호출(`tt --config-view`). 각 줄 `키 · 현재값 · 한 줄 설명`
- Enter:
  - boolean → 즉시 토글·저장·reload
  - 숫자/색 → fzf `print-query` 로 입력받아 검증 후 저장
  - `key_*` → **실제로 눌러서 캡처**. `execute()` 안에서 `read -rsn1 </dev/tty` 로 받아
    `ctrl-n` 형태로 역매핑한다. "누르세요"가 "ctrl-n 이라고 적으세요"보다 낫다
- Esc → 세션 목록 복귀. 색 변경은 다음 렌더부터 반영

### 8. 떠날 때 스냅샷

지금 기록 기회는 `--cron` 1분 주기와 팝업 열기 둘뿐이다. `snapshot=off` 로 크론을 끈 사람에게는
기록이 아예 없어진다 — 끄기를 열어주는 순간 **떠날 때 한 번**이 필요해진다.

트리거는 tmux 훅으로 잡는다. 실측(2026-08-04, tmux 3.5a, 별도 소켓):

| 상황 | 발화 훅 | 확인 |
|---|---|---|
| 붙어 있던 터미널이 강제로 죽음(창 닫힘·SSH 끊김) | `client-detached` | ✅ 클라이언트 SIGKILL 로 재현 |
| `kill-server`·마지막 세션 종료 | `session-closed` | ✅ 서버가 무너지는 중에도 `run-shell` 이 실행됨 |

```tmux
# ~/.config/fleetmux/tmux.conf — fmux 가 소유하는 파일 (소환키와 같은 자리)
set-hook -g client-detached 'run-shell -b "tt --snapshot >/dev/null 2>&1"'
set-hook -g session-closed  'run-shell "tt --snapshot >/dev/null 2>&1"'
```

- `client-detached` 는 `-b`(백그라운드). 떠나는 사람을 스냅샷이 붙잡으면 안 된다.
- `session-closed` 는 **동기**. 서버가 내려가는 중이라 백그라운드로 던지면 실행 전에 사라질 수 있다.
- 서버 붕괴 중 세션 열거가 0줄이어도 안전하다 — `--snapshot` 은 살아있는 세션이 0이면 아예
  쓰지 않는다(`70-fleet.sh:103`). 대장이 가장 필요한 순간에 증발하는 경로는 이미 막혀 있다.
- 동시 실행은 매니페스트 flock 이 직렬화한다(크론 틱과 겹쳐도 안전).

설정 키를 하나 더 둔다 — 크론과 종료 훅은 원하는 사람이 다르다:

| 키 | 기본 | 뜻 |
|---|---|---|
| `snapshot` | `on` | `--cron` 의 1분 주기 기록 |
| `snapshot_on_exit` | `on` | 떠날 때(detach·세션 닫힘) 기록 |

`snapshot_on_exit=off` 면 스니펫 생성 시 두 `set-hook` 줄을 빼고, tmux 안이면 즉시 반영한다.

## 끄기의 의미 (문서에 명시)

- `rc=off` 는 이미 붙은 Remote Control 링크를 끊지 않는다. **자동 재실행만** 멈춘다
- `snapshot=off` 면 매니페스트가 늙는다. `--restore` 의 "7일 낡음" 경고는 버그가 아니라 결과다
- **사용자 crontab 은 건드리지 않는다.** 끄기는 fmux 내부의 조기 return 으로 구현한다.
  남의 스케줄러를 프로그램이 조용히 고치지 않는다

## 실패 모드와 대응

| 상황 | 대응 |
|---|---|
| 설정 파일 깨짐/권한 없음 | 전부 기본값으로 동작 + 경고 1줄. 절대 중단하지 않는다 |
| 모르는 키 | 무시 + 경고. 구버전 fmux 가 신버전 설정을 만나도 산다 |
| 잘못된 키 이름 | 그 키만 기본값 복귀 + 경고 |
| fzf 기동 실패 | 기본 바인딩으로 재시도 |
| `set` 도중 중단 | tmp+mv 라 원본이 남는다 |

## 테스트

지금 `test/` 가 없다. 파서가 신뢰의 핵이므로 여기만 만든다 (순수 bash, 의존 없음):

- 깨진 줄·모르는 키를 무시하고 나머지를 읽는다
- env 가 파일을 이기고, 파일이 기본값을 이긴다
- `set` 이 주석·순서를 보존하고 원자적으로 쓴다
- 예약키 재매핑과 키 충돌을 거부한다
- 잘못된 키 이름이 그 키만 기본값으로 되돌린다

`make check` 에 물린다.

## 문서

- README 에 `Configuration` 절 — 파일 위치, 키 표, `tt config` 사용법, "끄기의 의미"
- `--help` 에 `config` 한 줄 추가
- README 의 libexec 경로 오기(`libexec/fleetmux` → `libexec/tt`) 동시 수정

## 후속 (이번 범위 아님)

- 설정 화면에서 키 충돌을 미리 보여주기
- 테마 프리셋
- 프로젝트별 설정
