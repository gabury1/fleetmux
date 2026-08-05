# fleetmux — bin/fmux 는 src/*.sh 를 번호 순서대로 이어붙인 산출물이다.
#
# 순서가 곧 의미다. bash 에는 진입점 함수가 없다 — 파일이 위에서 아래로 실행되면서
# ① 함수 정의문이 실행돼야 그 이름이 등록되고
# ② 서브커맨드는 `if [ "${1:-}" = "--x" ]; then …; exit 0; fi` 체인이라 먼저 나오는 분기가 이긴다.
# 그래서 번호 접두사가 실행 순서를 고정하고, SRC 목록의 나열 순서가 최종 파일의 순서다.
# 순서를 바꾸면 동작이 바뀐다.
#
# 각 파일이 담은 것:
#   00-header.sh   셔뱅·set -euo pipefail·LC_ALL·STATE·자기 절대경로 해석(tt_self/SELF/SELFQ)
#   05-config.sh   설정 — 화이트리스트 파서·env>파일>기본 우선순위·tt_conf_get/on/source
#   10-util.sh     이식성 헬퍼(tt_comm)·bash 3.2 분기(TT_TINY_READ)·hook.log 회전
#   20-manifest.sh 매니페스트 경로/형식·uuid 판정·무결성 검사(awk)·원자적 쓰기·백업 3세대
#   30-state.sh    상태 판정 계층 — 화면 작업중 판정(tt_working)·finished 락/정규화·
#                  훅 파일 유효성(tt_hook_valid)·tt_is_agent·tt_broadcast·훅 sweep·tt_jv
#   35-lastprompt.sh 마지막 프롬프트(last-<sid>) — payload 에서 뽑는 awk 스캐너·저장 함수·
#                  프리뷰 헤더 렌더 awk. 50(훅)과 90(프리뷰)이 둘 다 쓰므로 그 앞이다.
#   40-mfops.sh    매니페스트 변이 — 락·줄 조회·upsert·rename·forget
#   50-hook.sh     함대 집계(tt_fleet_agg)·--hook 수신부(working/idle/waiting/clear/boot)·--status
#   60-rc.sh       rc 판정 헬퍼(rc_*)·--cron(=--rc-check)·--rc
#   70-fleet.sh    tt_conv_of·--snapshot·--forget·--restore
#   80-view.sh     --list
#   85-config-cli.sh 설정 CLI — 검증·원자적 쓰기·tt config 하위명령
#   86-config-view.sh 팝업 안 설정 화면 — --config-list/--config-toggle/--config-view
#   87-tmux-conf.sh  tmux 스니펫 생성 — 소환키 바인딩·떠날 때 스냅샷 훅(--tmux-conf [--write])
#                    85 보다 뒤다: `tt config set` 은 85 에서 exit 하므로 여기 함수를 못 본다.
#                    그래서 85 는 함수를 직접 부르지 않고 `$SELF --tmux-conf --write` 로 재호출한다.
#   90-main.sh     tt_prompt·--do-*·--preview·--hooks-json·--codex-hooks·--help·진입점(fzf 팝업)
#
# 셔뱅은 00-header.sh 에만 있어야 한다 — 다른 파일에 넣으면 합친 결과 한가운데 셔뱅이 박힌다.
# 파일을 추가하면 아래 SRC 목록에도 번호 순서대로 넣을 것(글롭이 아니라 이 목록이 정답이다).

SRC = src/00-header.sh \
      src/05-config.sh \
      src/10-util.sh \
      src/20-manifest.sh \
      src/30-state.sh \
      src/35-lastprompt.sh \
      src/40-mfops.sh \
      src/50-hook.sh \
      src/60-rc.sh \
      src/70-fleet.sh \
      src/80-view.sh \
      src/85-config-cli.sh \
      src/86-config-view.sh \
      src/87-tmux-conf.sh \
      src/90-main.sh

OUT    = bin/fmux
PREFIX = $(HOME)/.local
BINDIR = $(PREFIX)/bin

all: $(OUT)

$(OUT): $(SRC)
	cat $(SRC) > $(OUT)
	chmod +x $(OUT)
	bash -n $(OUT)
	@echo "built $(OUT)"

# 문법 검사. shellcheck 는 있으면 돌리고, 없으면 건너뛴 사실을 말한다.
check: $(OUT)
	bash -n $(OUT)
	bash -n install.sh
	@if command -v shellcheck > /dev/null 2>&1; then \
		shellcheck -x $(OUT) && echo "shellcheck: clean"; \
		shellcheck install.sh || echo "shellcheck: install.sh 에 지적이 있다 — 아직 게이트가 아니다(아무도 클린을 확인한 적이 없다). 고치면 위 줄에 합쳐라"; \
	else \
		echo "shellcheck not installed — skipped"; \
	fi
	@./test/run.sh

# 분할 검증: src/*.sh 를 이어붙인 결과가 커밋된 bin/fmux 와 바이트 동일한지 본다.
# 차이가 하나라도 있으면 이 분할은 move-only 가 아니다.
verify:
	@t=$${TMPDIR:-/tmp}/fmux-verify.$$$$; \
	cat $(SRC) > $$t.joined; \
	git show HEAD:$(OUT) > $$t.head; \
	if diff -u $$t.head $$t.joined; then \
		rm -f $$t.joined $$t.head; \
		echo "verify: src/*.sh joins byte-identically to the committed $(OUT)"; \
	else \
		rm -f $$t.joined $$t.head; \
		echo "verify: MISMATCH — the split is not move-only"; \
		exit 1; \
	fi

install: $(OUT)
	mkdir -p $(BINDIR)
	cp $(OUT) $(BINDIR)/fmux
	chmod +x $(BINDIR)/fmux
	@echo "installed $(BINDIR)/fmux"
# tt 심링크. `make install` 만 쳐도 쓸 수 있는 상태여야 한다 — PATH shim(libexec/claude)은
# `command -v tt` 로 우리 존재를 확인하므로, 이 이름이 없으면 훅 주입이 통째로 안 붙는다.
# 남의 tt 는 절대 덮지 않는다 — 설치기가 남의 도구를 지우면 안 된다.
#   ⚠️ 예전 가드는 `[ -e ] && [ ! -L ]` 이었다: 일반 파일만 지키고 **남의 심링크는 갈아쳤다**.
#   ~/.local/bin 에 개인 도구를 거는 가장 흔한 방식이 심링크라, 이 주석이 코드를 거짓 진술한
#   상태였다(팀 배포 게이트 I2). install.sh 는 make 가 있으면 이 규칙을 그대로 물려받으므로
#   여기와 install.sh 의 tt_link_ours 는 **같은 판정**이어야 한다: 비었거나 fmux 를 가리키는
#   심링크일 때만 건다.
	@if [ ! -e "$(BINDIR)/tt" ] && [ ! -L "$(BINDIR)/tt" ]; then \
		ln -sf fmux "$(BINDIR)/tt"; \
		echo "linked $(BINDIR)/tt -> fmux"; \
	elif [ -L "$(BINDIR)/tt" ] && { [ "$$(readlink "$(BINDIR)/tt")" = fmux ] || [ "$$(readlink "$(BINDIR)/tt")" = "$(BINDIR)/fmux" ]; }; then \
		ln -sf fmux "$(BINDIR)/tt"; \
		echo "relinked $(BINDIR)/tt -> fmux"; \
	else \
		echo "skip: $(BINDIR)/tt 는 우리 것이 아니다 — 건드리지 않는다"; \
		echo "      지금 그 자리: $$(ls -ld "$(BINDIR)/tt")"; \
	fi

.PHONY: all check verify install
