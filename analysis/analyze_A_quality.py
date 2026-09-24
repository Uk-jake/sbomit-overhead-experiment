#!/usr/bin/env python3
"""
analyze_A_quality.py - 측정 데이터의 품질 검증

논문 수치를 뽑기 전에 5회 반복 측정이 신뢰할 만한지 확인한다.
세 가지를 본다.
  A1. 재현성      - 프로젝트별 5회 값의 변동계수(CV)
  A2. 순서 편향   - arm_position 에 따른 체계적 차이
  A3. outlier     - 특정 rep 에서만 튀는 값

사용법:
  python3 analyze_A_quality.py [overhead.jsonl 경로]
"""

import json, sys, statistics as st
from collections import defaultdict

PATH = sys.argv[1] if len(sys.argv) > 1 else \
    "/home/jake/sbomit-overhead-experiment/results/overhead.jsonl"

# ----------------------------------------------------------------------
# 로드. ptrace 는 rep 1 의 43개 부분 표본이라 품질 검증에서 제외한다.
# ----------------------------------------------------------------------
recs = []
with open(PATH) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            continue
        if r.get("status") == "ok" and r.get("arm") in ("clean", "ebpf"):
            recs.append(r)

# (dir, arm) -> {rep: record}
byk = defaultdict(dict)
name_of, lang_of = {}, {}
for r in recs:
    byk[(r["dir"], r["arm"])][r["rep"]] = r
    name_of[r["dir"]] = r["name"]
    lang_of[r["dir"]] = r.get("lang", "?")

dirs = sorted({d for d, _ in byk})
print(f"프로젝트 {len(dirs)}개, 유효 레코드 {len(recs)}건\n")


def cv(xs):
    """변동계수(%). 표준편차 / 평균. 값의 절대 크기와 무관하게 흩어짐을 비교"""
    if len(xs) < 2:
        return None
    m = st.mean(xs)
    return (st.stdev(xs) / m * 100) if m else None


# ======================================================================
# A1. 재현성
# ======================================================================
print("=" * 74)
print("A1. 재현성 — 프로젝트별 5회 측정의 변동계수(CV)")
print("=" * 74)

cvs = {"clean": [], "ebpf": []}
rows = []
for d in dirs:
    row = {"dir": d, "name": name_of[d], "lang": lang_of[d]}
    for arm in ("clean", "ebpf"):
        vals = [byk[(d, arm)][k]["elapsed_sec"] for k in sorted(byk[(d, arm)])]
        row[arm] = vals
        row[arm + "_med"] = st.median(vals) if vals else None
        c = cv(vals)
        row[arm + "_cv"] = c
        if c is not None:
            cvs[arm].append((c, d))
    rows.append(row)

for arm in ("clean", "ebpf"):
    v = sorted(x[0] for x in cvs[arm])
    n = len(v)
    print(f"\n[{arm}]  n={n}")
    print(f"  CV 중앙값 {st.median(v):5.1f}%   평균 {st.mean(v):5.1f}%"
          f"   최소 {v[0]:4.1f}%   최대 {v[-1]:5.1f}%")
    # 판정 기준: 5% 이내 안정, 10% 이내 허용, 20% 초과는 주의
    b = [sum(1 for x in v if x < 5),
         sum(1 for x in v if 5 <= x < 10),
         sum(1 for x in v if 10 <= x < 20),
         sum(1 for x in v if x >= 20)]
    print(f"  CV<5% {b[0]:3d}개 ({b[0]/n*100:4.1f}%) | 5~10% {b[1]:3d}개 | "
          f"10~20% {b[2]:3d}개 | >=20% {b[3]:3d}개")

print("\n--- CV 상위 10개 (변동이 큰 프로젝트) ---")
print(f"{'CV%':>6} {'arm':<6} {'project':<24} {'5회 측정값(초)'}")
allcv = [(c, arm, d) for arm in ("clean", "ebpf") for c, d in cvs[arm]]
for c, arm, d in sorted(allcv, reverse=True)[:10]:
    vals = [byk[(d, arm)][k]["elapsed_sec"] for k in sorted(byk[(d, arm)])]
    print(f"{c:6.1f} {arm:<6} {name_of[d][:23]:<24} "
          + " ".join(f"{v:.1f}" for v in vals))

# ======================================================================
# A2. 순서 편향
#
# arm 이 2개이므로 rep 1,3,5 는 clean 이 먼저, rep 2,4 는 ebpf 가 먼저다.
# "먼저 실행된 arm" 이 체계적으로 느리거나 빠른지 본다.
# 프로젝트별로 정규화한 뒤 집계해야 큰 프로젝트에 지배되지 않는다.
# ======================================================================
print("\n" + "=" * 74)
print("A2. 순서 편향 — arm_position 에 따른 체계적 차이")
print("=" * 74)

for arm in ("clean", "ebpf"):
    first, second = [], []      # 프로젝트 median 대비 비율
    for d in dirs:
        vals = {k: v for k, v in byk[(d, arm)].items()}
        med = st.median([v["elapsed_sec"] for v in vals.values()])
        if not med:
            continue
        for rep, r in vals.items():
            ratio = r["elapsed_sec"] / med
            (first if r.get("arm_position") == 1 else second).append(ratio)
    if not first or not second:
        continue
    print(f"\n[{arm}]")
    print(f"  1번째 실행: n={len(first):3d}  중앙값 {st.median(first):.4f}")
    print(f"  2번째 실행: n={len(second):3d}  중앙값 {st.median(second):.4f}")
    diff = (st.median(first) - st.median(second)) * 100
    verdict = "무시 가능" if abs(diff) < 2 else ("경미" if abs(diff) < 5 else "주의 필요")
    print(f"  차이: {diff:+.2f}%p  →  {verdict}")

# rep 별 전체 수준 이동 (시스템 상태 변화 탐지)
print("\n--- rep 별 수준 (프로젝트 median 대비 비율의 중앙값) ---")
print(f"{'rep':<5} {'clean':>10} {'ebpf':>10}")
for rep in range(1, 6):
    line = f"{rep:<5}"
    for arm in ("clean", "ebpf"):
        rs = []
        for d in dirs:
            vals = byk[(d, arm)]
            if rep not in vals:
                continue
            med = st.median([v["elapsed_sec"] for v in vals.values()])
            if med:
                rs.append(vals[rep]["elapsed_sec"] / med)
        line += f"{st.median(rs):10.4f}" if rs else f"{'-':>10}"
    print(line)
print("  (1.0 에서 크게 벗어난 rep 이 있으면 그 시점 시스템 상태를 의심)")

# ======================================================================
# A3. outlier
#
# 각 프로젝트의 median 대비 몇 배인지로 판단한다.
# 절대 시간 기준으로는 큰 프로젝트만 걸리므로 상대값을 쓴다.
# ======================================================================
print("\n" + "=" * 74)
print("A3. outlier — 프로젝트 median 대비 편차가 큰 개별 측정")
print("=" * 74)

outs = []
for d in dirs:
    for arm in ("clean", "ebpf"):
        vals = byk[(d, arm)]
        med = st.median([v["elapsed_sec"] for v in vals.values()])
        if not med:
            continue
        for rep, r in vals.items():
            ratio = r["elapsed_sec"] / med
            if ratio > 1.3 or ratio < 0.77:      # median 대비 ±30%
                outs.append((ratio, d, arm, rep, r["elapsed_sec"], med,
                             r.get("arm_position")))

print(f"\n±30% 초과 측정: {len(outs)}건 / 전체 {len(recs)}건 "
      f"({len(outs)/len(recs)*100:.1f}%)")
if outs:
    print(f"\n{'배율':>6} {'arm':<6} {'rep':<4} {'pos':<4} {'값':>9} {'median':>9}  project")
    for ratio, d, arm, rep, val, med, pos in sorted(outs, key=lambda x: -abs(x[0] - 1))[:15]:
        print(f"{ratio:6.2f} {arm:<6} {rep:<4} {pos if pos else '-':<4} "
              f"{val:9.1f} {med:9.1f}  {name_of[d][:30]}")

# ======================================================================
# 종합 판정
# ======================================================================
print("\n" + "=" * 74)
print("종합")
print("=" * 74)
med_cv_clean = st.median([c for c, _ in cvs["clean"]])
med_cv_ebpf = st.median([c for c, _ in cvs["ebpf"]])
out_pct = len(outs) / len(recs) * 100

print(f"  CV 중앙값        clean {med_cv_clean:.1f}%  ebpf {med_cv_ebpf:.1f}%")
print(f"  outlier 비율     {out_pct:.1f}%")
if med_cv_clean < 10 and med_cv_ebpf < 10 and out_pct < 5:
    print("  → 5회 반복으로 median 을 쓰기에 충분히 안정적")
elif med_cv_clean < 20 and med_cv_ebpf < 20:
    print("  → median 사용 가능. 변동이 큰 프로젝트는 개별 표시 권장")
else:
    print("  → 변동이 큼. median 사용과 함께 IQR 을 반드시 병기할 것")

# CSV 저장 (B 단계에서 재사용)
import csv
out_csv = PATH.rsplit("/", 1)[0] + "/A_quality.csv"
with open(out_csv, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["dir", "name", "lang", "clean_median", "clean_cv",
                "ebpf_median", "ebpf_cv"])
    for r in rows:
        w.writerow([r["dir"], r["name"], r["lang"],
                    f"{r['clean_med']:.3f}" if r["clean_med"] else "",
                    f"{r['clean_cv']:.2f}" if r["clean_cv"] is not None else "",
                    f"{r['ebpf_med']:.3f}" if r["ebpf_med"] else "",
                    f"{r['ebpf_cv']:.2f}" if r["ebpf_cv"] is not None else ""])
print(f"\n  프로젝트별 상세: {out_csv}")
