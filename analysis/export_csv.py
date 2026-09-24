#!/usr/bin/env python3
"""
export_csv.py - 실험 결과를 wide / long 두 형식의 CSV 로 내보낸다

wide  (93행)  한 행 = 한 프로젝트. rep 1~5 가 열로 펼쳐지고 median, ratio 포함.
              논문 표와 공유용. Excel 에서 정렬/비교하기 좋다.
long  (930행) 한 행 = 한 측정. pandas/R 등에서 다루는 표준 형태.
              나중에 열을 추가하거나 재집계할 때 쓴다.

repo_url 은 JSONL 에 없으므로 projects.tsv 에서 dir 을 키로 조인한다.

사용법:
  python3 export_csv.py [overhead.jsonl] [projects.tsv]
"""

import json, sys, csv, os, statistics as st
from collections import defaultdict

ROOT = "/home/jake/sbomit-overhead-experiment"
PATH = sys.argv[1] if len(sys.argv) > 1 else f"{ROOT}/results/overhead.jsonl"
TSV = sys.argv[2] if len(sys.argv) > 2 else f"{ROOT}/config/projects.tsv"
OUTDIR = os.path.dirname(PATH)

REPS = [1, 2, 3, 4, 5, 6, 7, 8]

# ----------------------------------------------------------------------
# projects.tsv 에서 repo_url 조회표 구성
# 컬럼: name / repo_url / dir / build_dir / build_cmd / lang
# ----------------------------------------------------------------------
url_by_dir = {}
cmd_by_dir = {}
lang_by_dir = {}
with open(TSV, encoding="utf-8") as f:
    header = f.readline()
    for line in f:
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 6:
            url_by_dir[parts[2]] = parts[1]
            cmd_by_dir[parts[2]] = parts[4]
            lang_by_dir[parts[2]] = parts[5]
        elif len(parts) >= 3:
            url_by_dir[parts[2]] = parts[1]

# ----------------------------------------------------------------------
# JSONL 로드. clean / ebpf 만 사용한다.
# ptrace 는 rep 1 의 43개 부분 표본이라 이 표에는 넣지 않는다.
# ----------------------------------------------------------------------
data = defaultdict(lambda: defaultdict(dict))   # dir -> arm -> rep -> record
meta = {}
skipped = 0
with open(PATH, encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            skipped += 1
            continue
        if r.get("status") != "ok" or r.get("arm") not in ("clean", "ebpf"):
            continue
        data[r["dir"]][r["arm"]][r["rep"]] = r
        meta[r["dir"]] = {
            "name": r["name"],
            "lang": r.get("lang", ""),
            "build_cmd": r.get("build_cmd", ""),
        }

dirs = sorted(data, key=lambda d: meta[d]["name"].lower())
print(f"프로젝트 {len(dirs)}개")
if skipped:
    print(f"  (파싱 실패 {skipped}줄 건너뜀)")

missing_url = [d for d in dirs if d not in url_by_dir]
if missing_url:
    print(f"  경고: repo_url 없음 {len(missing_url)}개 -> {', '.join(missing_url[:5])}")

# JSONL 에 build_cmd / lang 이 비어 있으면 projects.tsv 값으로 보완한다
for d in dirs:
    if not meta[d]["build_cmd"]:
        meta[d]["build_cmd"] = cmd_by_dir.get(d, "")
    if not meta[d]["lang"]:
        meta[d]["lang"] = lang_by_dir.get(d, "")


def f3(v):
    return f"{v:.3f}" if v is not None else ""


# ======================================================================
# wide format
# ======================================================================
wide_path = f"{OUTDIR}/results_wide.csv"
cols = ["project_name", "lang", "build_command", "github_url"]
cols += [f"clean_rep{r}" for r in REPS] + ["clean_median"]
cols += [f"ebpf_rep{r}" for r in REPS] + ["ebpf_median"]
cols += ["ratio", "delta_sec"]

with open(wide_path, "w", newline="", encoding="utf-8") as f:
    w = csv.writer(f)
    w.writerow(cols)
    for d in dirs:
        m = meta[d]
        row = [m["name"], m["lang"], m["build_cmd"], url_by_dir.get(d, "")]

        meds = {}
        for arm in ("clean", "ebpf"):
            vals = []
            for rep in REPS:
                rec = data[d][arm].get(rep)
                v = rec["elapsed_sec"] if rec else None
                vals.append(v)
                row.append(f3(v))
            got = [v for v in vals if v is not None]
            meds[arm] = st.median(got) if got else None
            row.append(f3(meds[arm]))

        if meds["clean"] and meds["ebpf"]:
            row.append(f"{meds['ebpf']/meds['clean']:.4f}")
            row.append(f3(meds["ebpf"] - meds["clean"]))
        else:
            row += ["", ""]
        w.writerow(row)

print(f"\nwide : {wide_path}  ({len(dirs)}행)")

# ======================================================================
# long format
# ======================================================================
long_path = f"{OUTDIR}/results_long.csv"
n_long = 0
with open(long_path, "w", newline="", encoding="utf-8") as f:
    w = csv.writer(f)
    w.writerow(["project_name", "lang", "build_command", "github_url",
                "rep", "arm", "duration_sec"])
    for d in dirs:
        m = meta[d]
        base = [m["name"], m["lang"], m["build_cmd"], url_by_dir.get(d, "")]
        for rep in REPS:
            for arm in ("clean", "ebpf"):
                rec = data[d][arm].get(rep)
                if rec is None:
                    continue
                w.writerow(base + [rep, arm, f3(rec["elapsed_sec"])])
                n_long += 1

print(f"long : {long_path}  ({n_long}행)")

# ======================================================================
# 검증
# ======================================================================
expected = len(dirs) * len(REPS) * 2
print(f"\n검증  기대 {expected}행 / 실제 {n_long}행", end="  ")
print("일치" if expected == n_long else "불일치 (결측 확인 필요)")

if expected != n_long:
    for d in dirs:
        for arm in ("clean", "ebpf"):
            miss = [r for r in REPS if r not in data[d][arm]]
            if miss:
                print(f"  결측: {meta[d]['name']} / {arm} / rep {miss}")
