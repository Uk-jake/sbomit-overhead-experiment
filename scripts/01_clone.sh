#!/usr/bin/env bash
#
# 01_clone.sh - 93개 CNCF 프로젝트를 clone하고 commit SHA를 고정 기록
#
# 빌드는 하지 않는다. clone 실패를 초반에 몰아서 발견하고,
# 이후 며칠짜리 빌드 실행 중에 upstream이 바뀌어도 영향받지 않도록
# 모든 repo의 commit SHA를 빌드 시작 전에 확정하는 것이 목적이다.
#
# 사용법:
#   sudo -i
#   source /home/jake/sbomit-overhead-experiment/config/env.sh
#   source /home/jake/sbomit-overhead-experiment/config/secrets.env   # GITHUB_TOKEN
#   bash /home/jake/sbomit-overhead-experiment/scripts/01_clone.sh
#
# 옵션:
#   --force <name|dir>   해당 프로젝트만 지우고 다시 clone
#   --retry-failed       이전 실행에서 실패한 것만 재시도
#   --dry-run            실제 clone 없이 파싱 결과만 출력

set -uo pipefail   # -e 는 쓰지 않는다. 한 프로젝트가 실패해도 계속 진행해야 함

# ----------------------------------------------------------------------
# 경로 설정
# ----------------------------------------------------------------------
EXP_ROOT="${EXP_ROOT:-/home/jake/sbomit-overhead-experiment}"
TSV="$EXP_ROOT/config/projects.tsv"
REPOS="$EXP_ROOT/repos"
RESULTS="$EXP_ROOT/results"
LOGS="$EXP_ROOT/logs/clone"
JSONL="$RESULTS/clones.jsonl"

mkdir -p "$REPOS" "$RESULTS" "$LOGS"

FORCE_TARGET=""
RETRY_FAILED=0
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)        FORCE_TARGET="$2"; shift 2 ;;
    --retry-failed) RETRY_FAILED=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# ----------------------------------------------------------------------
# 사전 점검
# ----------------------------------------------------------------------
[[ -f "$TSV" ]] || { echo "TSV 없음: $TSV" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq 필요" >&2; exit 1; }

# ----------------------------------------------------------------------
# GitHub 토큰 설정
#
# 토큰을 URL에 넣으면 remote.origin.url 과 ps 출력에 남는다.
# GIT_CONFIG_COUNT 방식은 환경변수로만 전달되어 gitconfig에 영구 저장되지 않고
# 프로세스 인자에도 노출되지 않는다. remote.origin.url 은 원본 URL 그대로 유지된다.
# ----------------------------------------------------------------------
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0="url.https://x-access-token:${GITHUB_TOKEN}@github.com/.insteadOf"
  export GIT_CONFIG_VALUE_0="https://github.com/"
  TOKEN_STATE="authenticated"
else
  TOKEN_STATE="anonymous"
  echo "경고: GITHUB_TOKEN 미설정. 익명 clone은 GitHub 쪽에서 throttle 될 수 있음" >&2
fi

# 자격증명 프롬프트로 멈추는 것 방지 (며칠짜리 무인 실행 대비)
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/true

echo "=== 01_clone.sh 시작 ==="
echo "TSV      : $TSV"
echo "repos    : $REPOS"
echo "auth     : $TOKEN_STATE"
echo "git      : $(git --version)"
echo

# ----------------------------------------------------------------------
# 이미 성공한 프로젝트 목록 (resumability)
# ----------------------------------------------------------------------
declare -A DONE=()
if [[ -f "$JSONL" && $RETRY_FAILED -eq 0 ]]; then
  while IFS= read -r d; do
    [[ -n "$d" ]] && DONE["$d"]=1
  done < <(jq -r 'select(.status=="ok") | .dir' "$JSONL" 2>/dev/null)
fi

# --retry-failed 인 경우: 실패한 dir만 대상으로 삼는다
declare -A RETRY_SET=()
if [[ $RETRY_FAILED -eq 1 && -f "$JSONL" ]]; then
  while IFS= read -r d; do
    [[ -n "$d" ]] && RETRY_SET["$d"]=1
  done < <(jq -r 'select(.status!="ok") | .dir' "$JSONL" 2>/dev/null)
  echo "재시도 대상: ${#RETRY_SET[@]}개"
fi

# ----------------------------------------------------------------------
# 결과 기록 (jq --arg 로 안전하게 JSON 생성. 이름에 공백/괄호가 있어도 깨지지 않음)
# ----------------------------------------------------------------------
record() {
  jq -nc \
    --arg name    "$1" \
    --arg dir     "$2" \
    --arg lang    "$3" \
    --arg url     "$4" \
    --arg status  "$5" \
    --arg commit  "$6" \
    --arg err     "$7" \
    --argjson elapsed "$8" \
    --argjson size_kb "$9" \
    --arg ts      "$(date -Is)" \
    '{name:$name, dir:$dir, lang:$lang, repo_url:$url, status:$status,
      commit:$commit, elapsed_sec:$elapsed, size_kb:$size_kb,
      error:$err, ts:$ts}' >> "$JSONL"
}

# ----------------------------------------------------------------------
# 메인 루프
# ----------------------------------------------------------------------
TOTAL=0; OK=0; SKIP=0; FAIL=0
START_ALL=$(date +%s)

# 헤더 1줄 건너뛰고 탭 구분으로 읽는다
# build_cmd 는 clone 단계에서 쓰지 않지만 컬럼 정합성 확인을 위해 같이 읽는다
while IFS=$'\t' read -r name url dir build_dir build_cmd lang; do
  [[ -z "${name:-}" ]] && continue
  TOTAL=$((TOTAL+1))

  # 컬럼 누락 검사
  if [[ -z "${dir:-}" || -z "${url:-}" ]]; then
    echo "[$TOTAL] SKIP (컬럼 누락): ${name:-?}"
    record "${name:-?}" "${dir:-}" "${lang:-}" "${url:-}" "malformed_row" "" "TSV 컬럼 누락" 0 0
    FAIL=$((FAIL+1)); continue
  fi

  DEST="$REPOS/$dir"

  # --force 지정 시 해당 항목만 처리
  if [[ -n "$FORCE_TARGET" ]]; then
    if [[ "$name" != "$FORCE_TARGET" && "$dir" != "$FORCE_TARGET" ]]; then
      continue
    fi
    echo "[force] 기존 디렉토리 제거: $DEST"
    rm -rf "$DEST"
  fi

  # --retry-failed 지정 시 실패 목록에 없으면 건너뛴다
  if [[ $RETRY_FAILED -eq 1 && -z "${RETRY_SET[$dir]:-}" ]]; then
    continue
  fi

  # 이미 성공 기록이 있고 디렉토리도 멀쩡하면 건너뛴다
  if [[ -z "$FORCE_TARGET" && -n "${DONE[$dir]:-}" && -d "$DEST/.git" ]]; then
    echo "[$TOTAL/93] SKIP (이미 clone됨): $name -> $dir"
    SKIP=$((SKIP+1)); continue
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    printf '[%d/93] DRY  %-28.28s dir=%-22.22s lang=%-6s cmd=%s\n' \
      "$TOTAL" "$name" "$dir" "$lang" "$build_cmd"
    continue
  fi

  # 부분 clone 잔여물 제거 후 시작
  rm -rf "$DEST"

  echo "[$TOTAL/93] CLONE $name -> $dir"
  LOG="$LOGS/$dir.log"
  T0=$(date +%s.%N)

  # --depth 1: 히스토리 불필요, 전송량과 시간 절약
  # --recurse-submodules: submodule을 쓰는 프로젝트 대비
  git clone --depth 1 --recurse-submodules --shallow-submodules \
      "$url" "$DEST" >"$LOG" 2>&1
  RC=$?

  T1=$(date +%s.%N)
  ELAPSED=$(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.3f", b-a}')

  if [[ $RC -ne 0 ]]; then
    # 토큰이 로그에 남을 가능성은 낮지만 방어적으로 마스킹
    ERR=$(tail -c 500 "$LOG" | tr -d '\000' | sed 's/x-access-token:[^@]*@/x-access-token:***@/g')
    echo "        FAIL (rc=$RC)"
    record "$name" "$dir" "$lang" "$url" "clone_fail" "" "$ERR" "$ELAPSED" 0
    FAIL=$((FAIL+1))
    rm -rf "$DEST"
    continue
  fi

  # commit SHA 고정 기록. 이 값이 이후 모든 rep의 기준이 된다
  COMMIT=$(git -C "$DEST" rev-parse HEAD 2>/dev/null)
  SIZE_KB=$(du -sk "$DEST" 2>/dev/null | cut -f1)
  : "${COMMIT:=}" ; : "${SIZE_KB:=0}"

  # build_dir 존재 확인. 없으면 빌드 단계에서 반드시 실패하므로 여기서 잡는다
  if [[ ! -d "$DEST/${build_dir:-.}" ]]; then
    echo "        FAIL (build_dir 없음: ${build_dir})"
    record "$name" "$dir" "$lang" "$url" "build_dir_missing" "$COMMIT" \
           "build_dir '${build_dir}' not found" "$ELAPSED" "$SIZE_KB"
    FAIL=$((FAIL+1)); continue
  fi

  printf '        OK   %ss  %s  %sMB\n' \
    "$ELAPSED" "${COMMIT:0:8}" "$((SIZE_KB/1024))"
  record "$name" "$dir" "$lang" "$url" "ok" "$COMMIT" "" "$ELAPSED" "$SIZE_KB"
  OK=$((OK+1))

done < <(tail -n +2 "$TSV")

# ----------------------------------------------------------------------
# 요약
# ----------------------------------------------------------------------
END_ALL=$(date +%s)
echo
echo "=== 완료 ($((END_ALL-START_ALL))초) ==="
echo "총 $TOTAL / 성공 $OK / 건너뜀 $SKIP / 실패 $FAIL"
echo "결과: $JSONL"

if [[ $FAIL -gt 0 && $DRY_RUN -eq 0 ]]; then
  echo
  echo "--- 실패 목록 ---"
  jq -r 'select(.status!="ok") | "\(.status)\t\(.name)\t\(.dir)"' "$JSONL" \
    | sort -u | column -t -s$'\t'
  echo
  echo "재시도: bash $0 --retry-failed"
fi

# root로 실행되므로 소유권을 jake로 돌려놓는다
if [[ $(id -u) -eq 0 && $DRY_RUN -eq 0 ]]; then
  chown -R jake:jake "$REPOS" "$RESULTS" "$LOGS" 2>/dev/null
fi
