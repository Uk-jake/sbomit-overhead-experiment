#!/usr/bin/env bash
#
# 02_clean_build.sh - 93개 프로젝트의 build_cmd 가 실제로 동작하는지 검증
#
# 목적은 시간 측정이 아니라 build command 정의를 확정하는 것이다.
# Phase 2(ptrace/ebpf)는 며칠 걸리는 작업이므로, 여기서 실패를 미리 걸러내지 않으면
# 본실험 중간에 실패가 쏟아진다.
#
# 캐시는 지우지 않는다 (warm). 검증 사이클을 짧게 가져가기 위함이며,
# 따라서 여기서 나온 elapsed_sec 은 Phase 2의 cold 값과 직접 비교할 수 없다.
# timeout 도 없다. 끝까지 기다린다.
#
# 사용법:
#   sudo -i
#   source /home/jake/sbomit-overhead-experiment/config/env.sh
#   bash /home/jake/sbomit-overhead-experiment/scripts/02_clean_build.sh
#
# 옵션:
#   --only <name|dir>          해당 프로젝트만 실행
#   --lang <go|python|rust>    해당 언어만 실행
#   --retry-failed             이전 실행에서 실패한 것만 재시도
#   --dry-run                  실행 계획만 출력

set -uo pipefail   # -e 미사용. 한 프로젝트가 실패해도 계속 진행해야 함

# ----------------------------------------------------------------------
# 경로 및 사전 점검
# ----------------------------------------------------------------------
EXP_ROOT="${EXP_ROOT:-/home/jake/sbomit-overhead-experiment}"
TSV="$EXP_ROOT/config/projects.tsv"
REPOS="$EXP_ROOT/repos"
RESULTS="$EXP_ROOT/results"
LOGS="$EXP_ROOT/logs/clean_build"
JSONL="$RESULTS/clean_build.jsonl"
CURRENT="$RESULTS/current_clean_build.txt"

mkdir -p "$RESULTS" "$LOGS"

ONLY=""; LANG_FILTER=""; RETRY_FAILED=0; DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)         ONLY="$2"; shift 2 ;;
    --lang)         LANG_FILTER="$2"; shift 2 ;;
    --retry-failed) RETRY_FAILED=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ -f "$TSV" ]]   || { echo "TSV 없음: $TSV" >&2; exit 1; }
[[ -d "$REPOS" ]] || { echo "repos 없음. 01_clone.sh 를 먼저 실행" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq 필요" >&2; exit 1; }

# env.sh 를 source 하지 않으면 PATH에 go/cargo/uv 가 없어 전부 실패한다.
# 여기서 미리 잡는다.
for v in EXP_ROOT HOME; do
  [[ -n "${!v:-}" ]] || { echo "ERROR: $v 미설정. env.sh 를 source 했는지 확인" >&2; exit 1; }
done
if ! command -v go >/dev/null; then
  echo "ERROR: go 를 찾을 수 없음. env.sh 를 source 했는지 확인" >&2
  echo "  source $EXP_ROOT/config/env.sh" >&2
  exit 1
fi

echo "=== 02_clean_build.sh 시작 ==="
echo "uid      : $(id -u)   HOME=$HOME"
echo "go       : $(go version 2>/dev/null)"
echo "GOMODCACHE: ${GOMODCACHE:-<unset>}"
echo "GOCACHE   : ${GOCACHE:-<unset>}"
echo "캐시 정책 : 삭제하지 않음 (warm)"
echo

# ----------------------------------------------------------------------
# resumability: 이미 성공한 항목 / 재시도 대상
# ----------------------------------------------------------------------
declare -A DONE=() RETRY_SET=()
if [[ -f "$JSONL" ]]; then
  if [[ $RETRY_FAILED -eq 1 ]]; then
    while IFS= read -r d; do [[ -n "$d" ]] && RETRY_SET["$d"]=1; done \
      < <(jq -r 'select(.status!="ok")|.dir' "$JSONL" 2>/dev/null | sort -u)
    echo "재시도 대상: ${#RETRY_SET[@]}개"
  else
    while IFS= read -r d; do [[ -n "$d" ]] && DONE["$d"]=1; done \
      < <(jq -r 'select(.status=="ok")|.dir' "$JSONL" 2>/dev/null | sort -u)
  fi
fi

# ----------------------------------------------------------------------
# 결과 기록. jq --arg 로 생성하므로 따옴표/개행이 섞여도 JSON이 깨지지 않는다
# ----------------------------------------------------------------------
record() {
  jq -nc \
    --arg name "$1" --arg dir "$2" --arg lang "$3" \
    --arg status "$4" --arg commit "$5" --arg cmd "$6" \
    --arg out "$7" --arg err "$8" \
    --argjson rc "$9" --argjson elapsed "${10}" \
    --arg ts "$(date -Is)" \
    '{name:$name, dir:$dir, lang:$lang, status:$status, exit_code:$rc,
      elapsed_sec:$elapsed, commit:$commit, build_cmd:$cmd,
      stdout_tail:$out, stderr_tail:$err, ts:$ts}' >> "$JSONL"
  sync -f "$JSONL" 2>/dev/null || true   # 며칠짜리 실행 대비, 즉시 디스크에 기록
}

# ----------------------------------------------------------------------
# 메인 루프
# ----------------------------------------------------------------------
TOTAL=0; RUN=0; OK=0; SKIP=0; FAIL=0
START_ALL=$(date +%s)

while IFS=$'\t' read -r name url dir build_dir build_cmd lang; do
  [[ -z "${name:-}" ]] && continue
  TOTAL=$((TOTAL+1))
  build_dir="${build_dir:-.}"

  # --- 필터 ---
  if [[ -n "$ONLY" && "$name" != "$ONLY" && "$dir" != "$ONLY" ]]; then continue; fi
  if [[ -n "$LANG_FILTER" && "$lang" != "$LANG_FILTER" ]]; then continue; fi
  if [[ $RETRY_FAILED -eq 1 && -z "${RETRY_SET[$dir]:-}" ]]; then continue; fi
  if [[ $RETRY_FAILED -eq 0 && -z "$ONLY" && -n "${DONE[$dir]:-}" ]]; then
    SKIP=$((SKIP+1)); continue
  fi

  RUN=$((RUN+1))
  REPO="$REPOS/$dir"

  if [[ $DRY_RUN -eq 1 ]]; then
    printf 'DRY  %-26.26s %-20.20s %-6s  %s\n' "$name" "$dir" "$lang" "$build_cmd"
    continue
  fi

  printf '[%3d/93] %-26.26s (%s) ... ' "$TOTAL" "$name" "$lang"

  if [[ ! -d "$REPO/.git" ]]; then
    echo "REPO_MISSING"
    record "$name" "$dir" "$lang" "repo_missing" "" "$build_cmd" "" \
           "repo not found: $REPO" 0 0
    FAIL=$((FAIL+1)); continue
  fi

  COMMIT=$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo "")

  # --- repo 를 clone 직후 상태로 되돌림 ---
  # 이전 빌드 산출물(bin/, dist/, target/, node_modules/)을 제거한다.
  # git clean 은 submodule 내용도 지울 수 있으므로 직후에 다시 초기화한다.
  RESET_LOG="$LOGS/$dir.reset.log"
  {
    git -C "$REPO" clean -xdff
    git -C "$REPO" checkout -- .
    if [[ -f "$REPO/.gitmodules" ]]; then
      git -C "$REPO" submodule update --init --recursive --depth 1
    fi
  } >"$RESET_LOG" 2>&1
  if [[ $? -ne 0 ]]; then
    echo "RESET_FAIL"
    record "$name" "$dir" "$lang" "reset_fail" "$COMMIT" "$build_cmd" "" \
           "$(tail -c 400 "$RESET_LOG")" 0 0
    FAIL=$((FAIL+1)); continue
  fi

  # --- 빌드 실행 ---
  LOG="$LOGS/$dir.log"
  echo "$(date -Is) project=$name dir=$dir cmd=$build_cmd" > "$CURRENT"

  T0=$(date +%s.%N)
  # subshell 로 감싸 cd 효과가 다음 프로젝트로 새지 않게 한다.
  # exec 를 쓰면 subshell 프로세스가 빌드로 대체되어 프로세스 계층이 한 단계 줄어든다.
  ( cd "$REPO/$build_dir" && exec sh -c "$build_cmd" ) >"$LOG" 2>&1
  RC=$?
  T1=$(date +%s.%N)
  ELAPSED=$(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.3f", b-a}')

  # 로그가 거대할 수 있으므로 꼬리만 JSONL 에 넣는다. 전체는 $LOG 에 남는다
  TAIL=$(tail -c 600 "$LOG" | tr -d '\000')

  if [[ $RC -eq 0 ]]; then
    printf 'OK    %8ss\n' "$ELAPSED"
    record "$name" "$dir" "$lang" "ok" "$COMMIT" "$build_cmd" "$TAIL" "" "$RC" "$ELAPSED"
    OK=$((OK+1))
  else
    printf 'FAIL  rc=%-3d %8ss\n' "$RC" "$ELAPSED"
    record "$name" "$dir" "$lang" "build_fail" "$COMMIT" "$build_cmd" "" "$TAIL" "$RC" "$ELAPSED"
    FAIL=$((FAIL+1))
  fi

done < <(tail -n +2 "$TSV")

rm -f "$CURRENT"

# ----------------------------------------------------------------------
# 요약
# ----------------------------------------------------------------------
END_ALL=$(date +%s)
echo
echo "=== 완료 ($((END_ALL-START_ALL))초) ==="
echo "대상 $RUN / 성공 $OK / 건너뜀 $SKIP / 실패 $FAIL"
echo "결과: $JSONL"
echo "로그: $LOGS/<dir>.log"

if [[ $FAIL -gt 0 && $DRY_RUN -eq 0 ]]; then
  echo
  echo "--- 실패 목록 ---"
  jq -rs 'group_by(.dir)|map(last)|.[]|select(.status!="ok")
          | "\(.status)\t\(.name)\t\(.dir)\t\(.build_cmd)"' "$JSONL" \
    | column -t -s$'\t' | cut -c1-160
  echo
  echo "개별 로그 확인:  less $LOGS/<dir>.log"
  echo "재시도:          bash $0 --retry-failed"
fi

if [[ $(id -u) -eq 0 && $DRY_RUN -eq 0 ]]; then
  chown -R jake:jake "$RESULTS" "$LOGS" 2>/dev/null
fi
