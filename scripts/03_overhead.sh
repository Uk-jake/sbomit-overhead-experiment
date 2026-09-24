#!/usr/bin/env bash
#
# 03_overhead.sh - clean / ptrace / ebpf 세 arm 의 빌드 시간을 측정
#
# 설계 결정 (합의 사항):
#   - 완전 cold: 매 run 마다 Go/Python/Rust 캐시를 전부 삭제
#   - timeout 없음: ptrace 가 몇 시간 걸리더라도 끝까지 기다린다
#   - 실행 순서: clean build 가 빠른 프로젝트부터 (build_order.txt)
#   - arm 순서: rep 마다 rotate 하여 "첫 arm 이 손해보는" 편향을 상쇄
#   - 측정: date +%s.%N wall clock. /usr/bin/time 은 쓰지 않는다
#   - reps=1 로 시작하고, 같은 JSONL 에 append 하여 4~5회까지 누적
#
# 사용법:
#   tmux new -s overhead
#   sudo -i
#   source /home/jake/sbomit-overhead-experiment/config/env.sh
#   bash /home/jake/sbomit-overhead-experiment/scripts/03_overhead.sh --rep 1
#
# 옵션:
#   --rep <N>              반복 회차 (기본 1). JSONL 에 rep 필드로 기록
#   --only <name|dir>      특정 프로젝트만
#   --arms <a,b,c>         실행할 arm 지정 (기본 clean,ptrace,ebpf)
#   --resume               이미 완료된 (dir,arm,rep) 조합은 건너뜀
#   --dry-run              실행 계획만 출력

set -uo pipefail

# ----------------------------------------------------------------------
# 경로
# ----------------------------------------------------------------------
EXP_ROOT="${EXP_ROOT:-/home/jake/sbomit-overhead-experiment}"
TSV="$EXP_ROOT/config/projects.tsv"
ORDER="$EXP_ROOT/results/build_order.txt"
REPOS="$EXP_ROOT/repos"
RESULTS="$EXP_ROOT/results"
LOGS="$EXP_ROOT/logs/overhead"
ATTS="$EXP_ROOT/attestations"
JSONL="$RESULTS/overhead.jsonl"
CURRENT="$RESULTS/current_overhead.txt"
KEY="${WITNESS_KEY:-$EXP_ROOT/config/keys/testkey.pem}"

mkdir -p "$RESULTS" "$LOGS" "$ATTS"

REP=1; ONLY=""; ARMS="clean,ptrace,ebpf"; RESUME=0; DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rep)     REP="$2"; shift 2 ;;
    --only)    ONLY="$2"; shift 2 ;;
    --arms)    ARMS="$2"; shift 2 ;;
    --resume)  RESUME=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# ----------------------------------------------------------------------
# 사전 검증
#
# env.sh 를 source 하지 않으면 PATH 에 go/cargo/uv 가 없어 전부 실패한다.
# 며칠짜리 실행이므로 여기서 반드시 잡는다.
# ----------------------------------------------------------------------
[[ -f "$TSV" ]]   || { echo "TSV 없음: $TSV" >&2; exit 1; }
[[ -d "$REPOS" ]] || { echo "repos 없음. 01_clone.sh 먼저 실행" >&2; exit 1; }
[[ -f "$KEY" ]]   || { echo "서명키 없음: $KEY" >&2; exit 1; }
command -v jq >/dev/null      || { echo "jq 필요" >&2; exit 1; }
command -v witness >/dev/null || { echo "witness 없음. env.sh source 확인" >&2; exit 1; }
command -v go >/dev/null      || { echo "go 없음. env.sh source 확인" >&2; exit 1; }
[[ $(id -u) -eq 0 ]] || { echo "root 필요 (eBPF). sudo -i 후 실행" >&2; exit 1; }

echo "=== 03_overhead.sh 시작 ==="
echo "rep      : $REP"
echo "arms     : $ARMS"
echo "uid      : $(id -u)   HOME=$HOME"
echo "kernel   : $(uname -r)"
echo "go       : $(go version)"
echo "witness  : $(witness version 2>/dev/null | head -1)"
echo "캐시     : 매 run 완전 삭제 (cold)"
echo "timeout  : 없음"
echo

# ----------------------------------------------------------------------
# 캐시 삭제
#
# 경로를 하드코딩한다. 환경변수를 쓰면 unset 일 때 rm -rf "" 가 되어
# 조용히 아무것도 지우지 않고, cold 라고 믿은 채 warm 으로 며칠을 돌게 된다.
# 그 실수는 실험 전체를 무효화하므로 변수를 쓰지 않는다.
#
# ~/.cargo/bin 은 건드리지 않는다. rustup toolchain 이 거기 있다.
# ----------------------------------------------------------------------
clear_caches() {
  # Go
  rm -rf /home/jake/go/pkg/mod  /home/jake/.cache/go-build
  rm -rf /root/go/pkg/mod       /root/.cache/go-build
  # Python
  rm -rf /home/jake/.cache/pip  /home/jake/.cache/uv
  rm -rf /root/.cache/pip       /root/.cache/uv
  # Rust (registry/git 만. bin 은 유지)
  rm -rf /home/jake/.cargo/registry /home/jake/.cargo/git
  rm -rf /root/.cargo/registry      /root/.cargo/git
  # C/C++
  rm -rf /home/jake/.cache/ccache /root/.cache/ccache
}

# repo 를 clone 직후 상태로 되돌린다 (이전 arm 의 산출물 제거)
reset_repo() {
  local repo="$1" log="$2"
  {
    git -C "$repo" clean -xdff
    git -C "$repo" checkout -- .
    [[ -f "$repo/.gitmodules" ]] && \
      git -C "$repo" submodule update --init --recursive --depth 1
  } >"$log" 2>&1
}

# ----------------------------------------------------------------------
# arm 순서 rotation
#
# 같은 순서를 고정하면 CDN edge cache 와 page cache 때문에
# 항상 첫 arm 이 손해를 본다. 이 편향은 방향이 정해져 있어 median 으로
# 사라지지 않으므로 rep 마다 순서를 돌린다.
# ----------------------------------------------------------------------
rotate_arms() {
  local rep="$1"; shift
  local -a a=("$@")
  # local 은 모든 할당을 먼저 확장한 뒤 실행하므로 n 과 shift_by 를 분리해야 한다
  local n=${#a[@]}
  local shift_by=$(( (rep - 1) % n ))
  local i
  for ((i=0; i<n; i++)); do
    echo -n "${a[$(( (i + shift_by) % n ))]} "
  done
}

IFS=',' read -r -a ARM_LIST <<< "$ARMS"

# ----------------------------------------------------------------------
# witness 로그에서 attestor 단계별 소요시간 파싱
#
# witness 는 "Finished command-run attestor... (2.86s)" 형태를 출력한다.
# command-run 값은 빌드 실행 구간만 잰 것이라, 전체 wall clock 에서 이를 빼면
# attestation collection(scaffolding) 비용을 별도 arm 없이 분리할 수 있다.
# ----------------------------------------------------------------------
parse_attestor_sec() {
  local log="$1" name="$2"
  grep -oP "Finished ${name} attestor\.\.\. \(\K[0-9.e-]+" "$log" 2>/dev/null \
    | tail -1 | awk '{printf "%.6f", $1+0}'
}

# ----------------------------------------------------------------------
# attestation 에서 관측 지표 추출
# ----------------------------------------------------------------------
attestation_metrics() {
  local f="$1"
  [[ -s "$f" ]] || { echo "0 0 0"; return; }
  jq -r .payload "$f" 2>/dev/null | base64 -d 2>/dev/null \
    | jq -r '[.predicate.attestations[]|select(.type|test("command-run"))|.attestation] as $a
             | ( ($a[0].processes // []) | length ) as $p
             | ( [ ($a[0].processes // [])[].openedfiles // {} | keys[] ]
                 | unique | length ) as $f
             | ( $a[0].exitcode // -1 ) as $e
             | "\($p) \($f) \($e)"' 2>/dev/null || echo "0 0 0"
}

# ----------------------------------------------------------------------
# 결과 기록. 프로젝트마다 즉시 append + sync (며칠짜리 실행 대비)
# ----------------------------------------------------------------------
record() {
  jq -nc \
    --arg name "$1" --arg dir "$2" --arg lang "$3" --arg arm "$4" \
    --arg status "$5" --arg commit "$6" --arg cmd "$7" --arg err "$8" \
    --argjson rep "$9"  --argjson pos "${10}" --argjson rc "${11}" \
    --argjson elapsed "${12}" --argjson cache_sec "${13}" \
    --argjson cmdrun "${14}" --argjson material "${15}" --argjson product "${16}" \
    --argjson procs "${17}" --argjson files "${18}" --argjson att_bytes "${19}" \
    --arg ts "${20}" \
    '{name:$name, dir:$dir, lang:$lang, arm:$arm, rep:$rep, arm_position:$pos,
      status:$status, exit_code:$rc,
      elapsed_sec:$elapsed, cache_clear_sec:$cache_sec,
      cmdrun_sec:$cmdrun, material_sec:$material, product_sec:$product,
      observed_processes:$procs, observed_files:$files, attestation_bytes:$att_bytes,
      commit:$commit, build_cmd:$cmd, stderr_tail:$err, ts:$ts}' >> "$JSONL"
  sync -f "$JSONL" 2>/dev/null || true
}

# 이미 완료된 (dir, arm, rep) 조합
declare -A DONE=()
if [[ $RESUME -eq 1 && -f "$JSONL" ]]; then
  while IFS= read -r k; do [[ -n "$k" ]] && DONE["$k"]=1; done \
    < <(jq -r --argjson r "$REP" \
        'select(.rep==$r and .status=="ok")|"\(.dir)|\(.arm)"' "$JSONL" 2>/dev/null)
  echo "resume: 완료된 조합 ${#DONE[@]}개는 건너뜀"
fi

# ----------------------------------------------------------------------
# 실행 대상 구성
#
# build_order.txt (clean build 빠른 순) 를 기준으로 정렬한다.
# 빠른 것부터 돌려야 며칠 안에 대부분의 데이터가 쌓이고, 중단해도 손실이 적다.
# ----------------------------------------------------------------------
declare -A META=()
while IFS=$'\t' read -r name url dir build_dir build_cmd lang; do
  [[ -z "${name:-}" ]] && continue
  META["$dir"]="$name"$'\t'"${build_dir:-.}"$'\t'"$build_cmd"$'\t'"$lang"
done < <(tail -n +2 "$TSV")

ORDERED=()
if [[ -f "$ORDER" ]]; then
  while IFS=$'\t' read -r _sec dir _n; do
    [[ -n "${META[$dir]:-}" ]] && ORDERED+=("$dir")
  done < "$ORDER"
fi
# build_order 에 없는 항목은 뒤에 붙인다
for d in "${!META[@]}"; do
  [[ " ${ORDERED[*]} " == *" $d "* ]] || ORDERED+=("$d")
done

echo "실행 대상: ${#ORDERED[@]}개 프로젝트 x ${#ARM_LIST[@]} arms"
echo "arm 순서 (rep $REP): $(rotate_arms "$REP" "${ARM_LIST[@]}")"
echo

# ----------------------------------------------------------------------
# 메인 루프
# ----------------------------------------------------------------------
IDX=0; NRUN=0; NOK=0; NFAIL=0; NSKIP=0
START_ALL=$(date +%s)
read -r -a ARM_ORDER <<< "$(rotate_arms "$REP" "${ARM_LIST[@]}")"

for dir in "${ORDERED[@]}"; do
  IFS=$'\t' read -r name build_dir build_cmd lang <<< "${META[$dir]}"
  IDX=$((IDX+1))

  if [[ -n "$ONLY" && "$name" != "$ONLY" && "$dir" != "$ONLY" ]]; then continue; fi

  REPO="$REPOS/$dir"
  COMMIT=$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo "")

  POS=0
  for arm in "${ARM_ORDER[@]}"; do
    POS=$((POS+1))

    if [[ -n "${DONE["$dir|$arm"]:-}" ]]; then
      NSKIP=$((NSKIP+1)); continue
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
      printf 'DRY [%2d/%d] %-24.24s arm=%-6s pos=%d  %s\n' \
        "$IDX" "${#ORDERED[@]}" "$name" "$arm" "$POS" "$build_cmd"
      continue
    fi

    NRUN=$((NRUN+1))
    printf '[%2d/%d] %-24.24s %-6s ' "$IDX" "${#ORDERED[@]}" "$name" "$arm"

    if [[ ! -d "$REPO/.git" ]]; then
      echo "REPO_MISSING"
      record "$name" "$dir" "$lang" "$arm" "repo_missing" "$COMMIT" "$build_cmd" \
             "repo not found" "$REP" "$POS" 0 0 0 0 0 0 0 0 0 "$(date -Is)"
      NFAIL=$((NFAIL+1)); continue
    fi

    # --- 준비 단계 (측정 대상 아님) ---
    C0=$(date +%s.%N)
    reset_repo "$REPO" "$LOGS/$dir.$arm.reset.log"
    clear_caches
    C1=$(date +%s.%N)
    CACHE_SEC=$(awk -v a="$C0" -v b="$C1" 'BEGIN{printf "%.3f", b-a}')

    LOG="$LOGS/$dir.$arm.rep$REP.log"
    ATT="$ATTS/$dir.$arm.rep$REP.json"
    echo "$(date -Is) project=$name arm=$arm rep=$REP cmd=$build_cmd" > "$CURRENT"

    # --- 측정 구간 ---
    # subshell 로 감싸 cd 효과가 다음 프로젝트로 새지 않게 한다.
    # exec 로 subshell 을 빌드 프로세스로 대체해 process tree 를 한 단계 줄인다.
    T0=$(date +%s.%N)
    case "$arm" in
      clean)
        ( cd "$REPO/$build_dir" && exec sh -c "$build_cmd" ) >"$LOG" 2>&1
        ;;
      ptrace)
        # backend 플래그를 주지 않으면 default(ptrace) 가 쓰인다.
        # witness 는 "ptrace" 라는 값을 받지 않는다.
        ( cd "$REPO/$build_dir" && exec witness run -s "$dir" -o "$ATT" -k "$KEY" \
            --trace -- sh -c "$build_cmd" ) >"$LOG" 2>&1
        ;;
      ebpf)
        ( cd "$REPO/$build_dir" && exec witness run -s "$dir" -o "$ATT" -k "$KEY" \
            --trace --attestor-command-run-trace-backend ebpf \
            -- sh -c "$build_cmd" ) >"$LOG" 2>&1
        ;;
      *) echo "unknown arm: $arm" >&2; continue ;;
    esac
    RC=$?
    T1=$(date +%s.%N)
    ELAPSED=$(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.3f", b-a}')

    # --- 지표 수집 ---
    CMDRUN=0; MATERIAL=0; PRODUCT=0; PROCS=0; FILES=0; ATT_BYTES=0
    if [[ "$arm" != "clean" ]]; then
      CMDRUN=$(parse_attestor_sec "$LOG" "command-run");  : "${CMDRUN:=0}"
      MATERIAL=$(parse_attestor_sec "$LOG" "material");   : "${MATERIAL:=0}"
      PRODUCT=$(parse_attestor_sec "$LOG" "product");     : "${PRODUCT:=0}"
      if [[ -s "$ATT" ]]; then
        read -r PROCS FILES _EXIT <<< "$(attestation_metrics "$ATT")"
        ATT_BYTES=$(stat -c%s "$ATT" 2>/dev/null || echo 0)
      fi
    fi
    : "${PROCS:=0}"; : "${FILES:=0}"; : "${ATT_BYTES:=0}"
    [[ "$CMDRUN" =~ ^[0-9.]+$ ]]   || CMDRUN=0
    [[ "$MATERIAL" =~ ^[0-9.]+$ ]] || MATERIAL=0
    [[ "$PRODUCT" =~ ^[0-9.]+$ ]]  || PRODUCT=0

    TAIL=$(tail -c 600 "$LOG" | tr -d '\000')

    if [[ $RC -eq 0 ]]; then
      STATUS="ok"; NOK=$((NOK+1))
      printf 'OK   %9ss' "$ELAPSED"
      [[ "$arm" != "clean" ]] && printf '  (cmdrun %ss, files %s)' "$CMDRUN" "$FILES"
      echo
      ERRTXT=""
    else
      # clean 이 성공했는데 traced arm 만 실패했다면 그 자체가 결과다.
      # 예외로 취급하지 않고 데이터로 남긴다.
      STATUS="build_fail"; NFAIL=$((NFAIL+1))
      printf 'FAIL rc=%-3d %9ss\n' "$RC" "$ELAPSED"
      ERRTXT="$TAIL"
    fi

    record "$name" "$dir" "$lang" "$arm" "$STATUS" "$COMMIT" "$build_cmd" "$ERRTXT" \
           "$REP" "$POS" "$RC" "$ELAPSED" "$CACHE_SEC" \
           "$CMDRUN" "$MATERIAL" "$PRODUCT" \
           "$PROCS" "$FILES" "$ATT_BYTES" "$(date -Is)"
  done
done

rm -f "$CURRENT"

# ----------------------------------------------------------------------
# 요약
# ----------------------------------------------------------------------
END_ALL=$(date +%s)
D=$((END_ALL-START_ALL))
echo
printf '=== 완료 (%dh %dm %ds) ===\n' $((D/3600)) $((D%3600/60)) $((D%60))
echo "실행 $NRUN / 성공 $NOK / 실패 $NFAIL / 건너뜀 $NSKIP"
echo "결과: $JSONL"

if [[ $DRY_RUN -eq 0 && -s "$JSONL" ]]; then
  echo
  echo "--- arm 별 중앙값 (rep $REP) ---"
  jq -rs --argjson r "$REP" \
    'map(select(.rep==$r and .status=="ok"))
     | group_by(.arm)[]
     | sort_by(.elapsed_sec) as $s
     | "\($s[0].arm)\t\($s|length)개\t중앙값 \($s[($s|length)/2|floor].elapsed_sec)초"' \
    "$JSONL" | column -t -s$'\t'

  FAILN=$(jq -rs --argjson r "$REP" \
    'map(select(.rep==$r and .status!="ok"))|length' "$JSONL")
  if [[ "$FAILN" -gt 0 ]]; then
    echo
    echo "--- 실패 ---"
    jq -rs --argjson r "$REP" \
      'map(select(.rep==$r and .status!="ok"))[]|"\(.arm)\t\(.name)\trc=\(.exit_code)"' \
      "$JSONL" | column -t -s$'\t'
  fi
fi

if [[ $(id -u) -eq 0 && $DRY_RUN -eq 0 ]]; then
  chown -R jake:jake "$RESULTS" "$LOGS" "$ATTS" 2>/dev/null
fi
