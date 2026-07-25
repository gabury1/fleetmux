# 매니페스트 변이 직렬화.
#   fd 8인 이유: fd 9는 finished·rc 락이 이미 쓴다 — idle 훅은 두 락을 겹쳐 잡을 수 있어서
#   같은 fd를 쓰면 서로의 락을 닫아버린다.
#   훅 경로에서도 불리므로 대기는 짧게. 못 잡으면 이번 기록만 포기한다 — 매니페스트 때문에
#   훅 본연의 동작(상태 갱신·완료 알림)이 늦어지면 배보다 배꼽이 크다.
tt_mf_lock() {
    local d="${MANIFEST%/*}"
    [ -d "$d" ] || mkdir -p "$d" 2>/dev/null || return 1
    command -v flock >/dev/null 2>&1 || return 0
    exec 8>"$MANIFEST.lock" 2>/dev/null || return 1
    flock -w 2 8 2>/dev/null || return 1
    return 0
}
tt_mf_unlock() { exec 8>&- 2>/dev/null || true; return 0; }

# 그 세션의 매니페스트 줄 한 개를 그대로 출력 (없으면 빈 출력)
tt_mf_row() {
    local line t=$'\t'
    [ -f "$MANIFEST" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in "$1$t"*) printf '%s' "$line"; return 0 ;; esac
    done < "$MANIFEST"
    return 0
}

# upsert — 그 세션의 줄을 갈아끼운다(없으면 추가).
#   ① 내용이 같으면 파일을 아예 안 쓴다. 훅은 초당 여러 번 불릴 수 있어서, 매번 쓰면
#      디스크와 훅 지연을 그냥 버리는 셈이다.
#   ② 빈 문자열 인자 = "이번엔 모르겠음" → 기존 값 보존. '-' = "확실히 없음"(덮어씀).
#      훅은 이벤트마다 아는 게 다르다(codex 훅엔 대화 id가 없고, 도구 실행 중엔 pane 명령이
#      claude가 아니다) — 모르는 필드가 기존 기록을 지우면 복원이 조용히 망가진다.
#   ③ 포크 0으로 짰다(문자열 연산 + printf 빌트인). 변경이 있을 때만 mv 한 번.
#   ④ 6번째 "대화 홈"도 같은 규칙을 따른다. 훅은 stdin JSON의 cwd로 이 값을 정확히 아는
#      유일한 지점이다 — claude가 자기 대화 폴더를 계산할 때 쓰는 바로 그 값이라서다.
tt_mf_upsert() {
    local name="$1" cwd="$2" kind="$3" cmd="$4" conv="$5" chome="${6:-}"
    local t=$'\t' line old="" o row out="" found=0
    [ -n "$name" ] || return 0
    case "$name" in *"$t"*) return 0 ;; esac   # 탭 든 이름은 형식을 깨뜨린다 — 기록 포기
    case "$cwd$kind$cmd$conv$chome" in *"$t"*) return 0 ;; esac
    tt_mf_lock || return 0
    # 1차: 옛 줄을 먼저 본다 (모르는 필드를 보존하려면 새 줄을 만들기 전에 옛 값이 필요)
    if [ -f "$MANIFEST" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in "$name$t"*) old="$line"; break ;; esac
        done < "$MANIFEST"
    fi
    if [ -n "$old" ]; then
        # 옛 줄은 5필드일 수 있다(6번째 도입 전 기록) — 그 경우 chome 자리는 없으니 빈 값이 남는다
        o=${old#*$t}; [ -n "$cwd" ]  || cwd=${o%%$t*}
        o=${o#*$t};   [ -n "$kind" ] || kind=${o%%$t*}
        o=${o#*$t};   [ -n "$cmd" ]  || cmd=${o%%$t*}
        o=${o#*$t};   [ -n "$conv" ] || conv=${o%%$t*}
        case "$o" in
            *"$t"*) o=${o#*$t}; [ -n "$chome" ] || chome=${o%%$t*} ;;
        esac
    fi
    [ -n "$cwd" ]   || cwd="-"
    [ -n "$kind" ]  || kind="tool"
    [ -n "$cmd" ]   || cmd="-"
    [ -n "$conv" ]  || conv="-"
    [ -n "$chome" ] || chome="-"
    # 대화 id는 uuid만 — "claude" 같은 밀린 값이 여기서 들어오면 무결성 검사가 이후의 모든
    # 쓰기를 거부해 대장이 통째로 얼어붙는다. 입구에서 잘라내는 게 싸다.
    tt_is_uuid "$conv" || conv="-"
    case "$kind" in agent|tool) ;; *) kind="tool" ;; esac
    row="$name$t$cwd$t$kind$t$cmd$t$conv$t$chome"
    [ "$old" = "$row" ] && { tt_mf_unlock; return 0; }   # 변경 없음 → 파일 무접촉
    # 2차: 제자리 치환 (순서 보존 — 사람이 읽는 파일이다)
    if [ -f "$MANIFEST" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            [ -n "$line" ] || continue
            case "$line" in
                "$name$t"*)
                    [ "$found" = 0 ] || continue      # 같은 이름이 두 줄이면 여기서 정리
                    found=1; out="$out$row"$'\n' ;;
                *) out="$out$line"$'\n' ;;
            esac
        done < "$MANIFEST"
    fi
    [ "$found" = 1 ] || out="$out$row"$'\n'
    tt_mf_write "$out" || true      # 검증 실패 = 기존 파일 보존 (조용히 이번 기록만 포기)
    tt_mf_unlock
    return 0
}

# 개명 추종 — tmux 세션 이름이 바뀌면 대장의 키도 같이 바뀌어야 한다(안 그러면 복원 때 유령 부활)
tt_mf_rename() {
    local old="$1" new="$2" t=$'\t' line out="" hit=0
    [ -n "$old" ] && [ -n "$new" ] || return 0
    [ -f "$MANIFEST" ] || return 0
    case "$new" in *"$t"*) return 0 ;; esac
    tt_mf_lock || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        case "$line" in
            "$old$t"*) hit=1; out="$out$new$t${line#*$t}"$'\n' ;;
            "$new$t"*) ;;                                    # 새 이름의 옛 줄은 개명이 이긴다
            *) out="$out$line"$'\n' ;;
        esac
    done < "$MANIFEST"
    [ "$hit" = 1 ] && { tt_mf_write "$out" || true; }
    tt_mf_unlock
    return 0
}

# 명시적 삭제 — 세션이 죽었다고 자동으로 지우지는 않는다(죽은 걸 살리는 게 이 파일의 목적).
#   지운 줄 수는 전역 TT_MF_HITS로 돌려준다.
tt_mf_forget() {
    local name="$1" t=$'\t' line out=""
    TT_MF_HITS=0
    [ -n "$name" ] || return 0
    [ -f "$MANIFEST" ] || return 0
    tt_mf_lock || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        case "$line" in
            "$name$t"*) TT_MF_HITS=$((TT_MF_HITS + 1)) ;;
            *) out="$out$line"$'\n' ;;
        esac
    done < "$MANIFEST"
    [ "$TT_MF_HITS" -gt 0 ] && { tt_mf_write "$out" || TT_MF_HITS=0; }
    tt_mf_unlock
    return 0
}

