#!/usr/bin/env python3
"""
analyze_B_overhead.py - eBPF tracing overhead 핵심 집계

A 단계에서 5회 측정의 CV 중앙값이 1% 내외로 확인되었으므로
프로젝트별 median 을 대표값으로 사용한다. median 은 극단값에 강하여
rep 1 의 일부 튀는 측정을 자동으로 흡수한다.

산출 항목
  B1. overhead 비율 분포     - median(ebpf)/median(clean)
  B2. 절대 시간 오버헤드     - median(ebpf) - median(clean)
  B3. 빌드 길이와의 관계     - 고정 비용이 짧은 빌드의 비율을 밀어올리는지
  B4. scaffolding 분해       - elapsed - cmdrun = attestation 수집 비용
  B5. 언어별 요약
  B6. 상위/하위 프로젝트

사용법:
  python3 analyze_B_overhead.py [overhead.jsonl 경로]
"""

import json, sys, csv, statistics as st
from collections import defaultdict

PATH = sys.argv[1] if len(sys.argv) > 1 else \
    "/home/jake/sbomit-overhead-experiment/results/overhead.jsonl"
OUTDIR = PATH.rsplit("/", 1)[0]

# ----------------------------------------------------------------------
# 로드
# ----------------------------------------------------------------------
raw = defaultdict(lambda: defaultdict(list))   # dir -> arm -> [record]
meta = {}
with open(PATH) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            continue
        if r.get("status") != "ok":
            continue
        raw[r["dir"]][r["arm"]].append(r)
        meta[r["dir"]] = (r["name"], r.get("lang", "?"))


def med(xs):
    return st.median(xs) if xs else None


def iqr(xs):
    if len(xs) < 4:
        return None
    q = st.quantiles(xs, n=4)
    return q[2] - q[0]


# ----------------------------------------------------------------------
# 프로젝트별 대표값 산출
# ----------------------------------------------------------------------
P = []
for d, arms in raw.items():
    if "clean" not in arms or "ebpf" not in arms:
        continue
    name, lang = meta[d]
    c = [r["elapsed_sec"] for r in arms["clean"]]
    e = [r["elapsed_sec"] for r in arms["ebpf"]]
    cm, em = med(c), med(e)
    if not cm:
        continue

    # cmdrun_sec 은 witness 로그에서 파싱한 빌드 실행 구간.
    # elapsed - cmdrun = git/material/product attestor 수집 + 서명 비용
    cr = [r.get("cmdrun_sec", 0) for r in arms["ebpf"] if r.get("cmdrun_sec")]
    crm = med(cr)

    P.append({
        "dir": d, "name": name, "lang": lang,
        "n_clean": len(c), "n_ebpf": len(e),
        "clean": cm, "ebpf": em,
        "clean_iqr": iqr(c), "ebpf_iqr": iqr(e),
        "ratio": em / cm,
        "delta": em - cm,
        "cmdrun": crm,
        "scaffold": (em - crm) if crm else None,
        "files": med([r.get("observed_files", 0) for r in arms["ebpf"]]),
        "procs": med([r.get("observed_processes", 0) for r in arms["ebpf"]]),
        "att_bytes": med([r.get("attestation_bytes", 0) for r in arms["ebpf"]]),
    })

P.sort(key=lambda x: x["clean"])
N = len(P)
print(f"분석 대상 {N}개 프로젝트 (프로젝트별 median 사용)\n")

ratios = sorted(p["ratio"] for p in P)
deltas = sorted(p["delta"] for p in P)


def pct(xs, q):
    return st.quantiles(xs, n=100)[q - 1]


# ======================================================================
print("=" * 74)
print("B1. eBPF overhead 비율  median(ebpf) / median(clean)")
print("=" * 74)
print(f"  중앙값   {st.median(ratios):.4f}x   ({(st.median(ratios)-1)*100:+.2f}%)")
print(f"  평균     {st.mean(ratios):.4f}x")
print(f"  P25      {pct(ratios,25):.4f}x")
print(f"  P75      {pct(ratios,75):.4f}x")
print(f"  P95      {pct(ratios,95):.4f}x")
print(f"  최소     {ratios[0]:.4f}x     최대 {ratios[-1]:.4f}x")

bands = [(0, 1.05), (1.05, 1.10), (1.10, 1.20), (1.20, 1.50), (1.50, 99)]
print("\n  분포")
for lo, hi in bands:
    k = sum(1 for r in ratios if lo <= r < hi)
    lbl = f"<{hi:.2f}x" if lo == 0 else (f">={lo:.2f}x" if hi == 99 else f"{lo:.2f}~{hi:.2f}x")
    bar = "█" * round(k / N * 50)
    print(f"    {lbl:>12}  {k:3d}개 ({k/N*100:5.1f}%) {bar}")

# ======================================================================
print("\n" + "=" * 74)
print("B2. 절대 시간 오버헤드  median(ebpf) - median(clean)")
print("=" * 74)
print(f"  중앙값   {st.median(deltas):7.2f}초")
print(f"  평균     {st.mean(deltas):7.2f}초")
print(f"  P25      {pct(deltas,25):7.2f}초      P75 {pct(deltas,75):7.2f}초")
print(f"  최소     {deltas[0]:7.2f}초      최대 {deltas[-1]:7.2f}초")
tot_c = sum(p["clean"] for p in P)
tot_e = sum(p["ebpf"] for p in P)
print(f"\n  전체 합계  clean {tot_c:8.1f}초 → ebpf {tot_e:8.1f}초"
      f"  (+{tot_e-tot_c:.1f}초, {(tot_e/tot_c-1)*100:+.2f}%)")

# ======================================================================
# B3. 빌드 길이와 overhead 비율의 관계
#
# smoke test 에서 eBPF backend 의 attach 고정 비용이 약 0.4초로 관측되었다.
# 이 고정 비용이 짧은 빌드에서 비율을 밀어올린다면, 빌드가 길어질수록
# 비율이 1.0 에 수렴해야 한다.
# ======================================================================
print("\n" + "=" * 74)
print("B3. 빌드 길이와 overhead 비율")
print("=" * 74)
buckets = [(0, 15, "~15초"), (15, 30, "15~30초"), (30, 60, "30~60초"),
           (60, 120, "60~120초"), (120, 1e9, "120초~")]
print(f"  {'clean 구간':<12} {'n':>4} {'비율 중앙값':>12} {'절대차 중앙값':>14}")
for lo, hi, lbl in buckets:
    g = [p for p in P if lo <= p["clean"] < hi]
    if not g:
        continue
    print(f"  {lbl:<12} {len(g):>4} {st.median([p['ratio'] for p in g]):>11.4f}x"
          f" {st.median([p['delta'] for p in g]):>13.2f}초")

# 상관계수 (Pearson). 관계의 방향과 강도를 수치로
xs = [p["clean"] for p in P]
ys = [p["ratio"] for p in P]
mx, my = st.mean(xs), st.mean(ys)
cov = sum((a - mx) * (b - my) for a, b in zip(xs, ys))
den = (sum((a - mx) ** 2 for a in xs) * sum((b - my) ** 2 for b in ys)) ** 0.5
print(f"\n  clean 시간 vs 비율  Pearson r = {cov/den:+.3f}"
      "   (음수면 긴 빌드일수록 비율이 낮음)")

# ======================================================================
# B4. scaffolding 분해
#
# witness 로그의 "Finished command-run attestor... (Xs)" 는 빌드 실행 구간만
# 측정한 값이다. 전체 elapsed 에서 이를 빼면 git/material/product attestor
# 수집과 서명에 든 비용이 나온다. 별도 arm 없이 얻은 분해다.
# ======================================================================
print("\n" + "=" * 74)
print("B4. overhead 구성  tracing vs attestation 수집(scaffolding)")
print("=" * 74)
has = [p for p in P if p["scaffold"] is not None]
if has:
    sc = sorted(p["scaffold"] for p in has)
    print(f"  n={len(has)}")
    print(f"  scaffolding  중앙값 {st.median(sc):6.2f}초"
          f"   P25 {pct(sc,25):.2f}초   P75 {pct(sc,75):.2f}초"
          f"   최대 {sc[-1]:.2f}초")
    # 전체 오버헤드 중 scaffolding 이 차지하는 비중
    share = [p["scaffold"] / p["delta"] * 100 for p in has if p["delta"] > 0]
    if share:
        share.sort()
        print(f"  오버헤드 대비 비중  중앙값 {st.median(share):5.1f}%"
              f"   P25 {pct(share,25):.1f}%   P75 {pct(share,75):.1f}%")
        print("  → 순수 tracing 비용은 측정된 오버헤드보다 더 작다")

# ======================================================================
print("\n" + "=" * 74)
print("B5. 언어별 요약")
print("=" * 74)
print(f"  {'lang':<8} {'n':>3} {'비율 중앙값':>12} {'절대차':>10} {'관측파일 중앙값':>16}")
for lang in sorted({p["lang"] for p in P}):
    g = [p for p in P if p["lang"] == lang]
    print(f"  {lang:<8} {len(g):>3} {st.median([p['ratio'] for p in g]):>11.4f}x"
          f" {st.median([p['delta'] for p in g]):>9.2f}초"
          f" {st.median([p['files'] for p in g]):>16,.0f}")
print("  (python 5개, rust 3개는 표본이 작아 정성적 참고만)")

# ======================================================================
print("\n" + "=" * 74)
print("B6. overhead 비율 상위/하위 10개")
print("=" * 74)
bys = sorted(P, key=lambda x: -x["ratio"])
for tag, sub in (("상위 (오버헤드 큼)", bys[:10]), ("하위 (오버헤드 작음)", bys[-10:])):
    print(f"\n  --- {tag} ---")
    print(f"  {'비율':>8} {'clean':>9} {'ebpf':>9} {'차이':>8}  {'files':>8}  project")
    for p in sub:
        print(f"  {p['ratio']:7.3f}x {p['clean']:9.2f} {p['ebpf']:9.2f}"
              f" {p['delta']:+8.2f}  {p['files']:8,.0f}  {p['name'][:28]}")

# ======================================================================
# CSV 저장
# ======================================================================
out = f"{OUTDIR}/B_overhead.csv"
with open(out, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["dir", "name", "lang", "n_clean", "n_ebpf",
                "clean_median_sec", "clean_iqr", "ebpf_median_sec", "ebpf_iqr",
                "ratio", "delta_sec", "cmdrun_sec", "scaffold_sec",
                "observed_files", "observed_processes", "attestation_bytes"])
    for p in sorted(P, key=lambda x: -x["ratio"]):
        w.writerow([p["dir"], p["name"], p["lang"], p["n_clean"], p["n_ebpf"],
                    f"{p['clean']:.3f}",
                    f"{p['clean_iqr']:.3f}" if p["clean_iqr"] is not None else "",
                    f"{p['ebpf']:.3f}",
                    f"{p['ebpf_iqr']:.3f}" if p["ebpf_iqr"] is not None else "",
                    f"{p['ratio']:.4f}", f"{p['delta']:.3f}",
                    f"{p['cmdrun']:.3f}" if p["cmdrun"] else "",
                    f"{p['scaffold']:.3f}" if p["scaffold"] is not None else "",
                    int(p["files"]), int(p["procs"]), int(p["att_bytes"])])
print(f"\n  프로젝트별 상세: {out}")
