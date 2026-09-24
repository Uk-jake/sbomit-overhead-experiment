# witness Build Overhead Experiment

Measures the build-time overhead of [witness](https://github.com/in-toto/witness) file tracing across 93 CNCF projects, comparing a plain build against the same build wrapped by `witness run --trace` with the eBPF backend.

## Setup

- **Projects:** 93 CNCF projects (85 Go, 5 Python, 3 Rust), shallow-cloned (`--depth 1`) with pinned commit SHAs
- **Arms:**
  - `clean`: `sh -c "<build_cmd>"`
  - `ebpf`: `witness run --trace --attestor-command-run-trace-backend ebpf -- sh -c "<build_cmd>"`
  - `ptrace` (default backend) was measured for 43 projects in rep 1 only and then dropped because of its run time
- **Cache policy:** fully cold. Go module/build caches, pip/uv caches and Cargo registry are deleted before every run, and each repo is reset with `git clean -xdff`
- **Repetitions:** each project is built repeatedly, and the order of the arms rotates each rep to cancel ordering bias
- **Timing:** wall clock via `date +%s.%N`. `/usr/bin/time` is not used
- **Environment:** single GCP VM, Ubuntu 22.04, kernel 6.8.0-1066-gcp, Go 1.26.5, run as root (required for eBPF)

## Repository layout

```
config/     projects.tsv (project list and build commands), env.sh, notes on excluded/adjusted projects and system dependencies
scripts/    01_clone.sh, 02_clean_build.sh (build command validation), 03_overhead.sh (measurement)
analysis/   data quality check (A), overhead analysis (B), CSV export
results/    raw measurements (overhead.jsonl) and derived CSVs (results_wide.csv, results_long.csv)
logs/       per-project build logs
```

Cloned repositories, caches and signed attestations are not included.

## Reproducing

```bash
sudo -i
source config/env.sh                                              # PATH, HOME and signing key location
bash scripts/01_clone.sh                                          # clone all projects, record commit SHAs
bash scripts/02_clean_build.sh                                    # check that every build command works
bash scripts/03_overhead.sh --rep 1 --arms clean,ebpf --resume    # repeat for each rep
python3 analysis/export_csv.py
```

`03_overhead.sh` requires a witness signing key at `config/keys/testkey.pem`, which is not part of this repository. Generate one with `openssl genpkey -algorithm ed25519 -out config/keys/testkey.pem`.

## Notes

- Five build commands were narrowed or adjusted so they build on the host without release packaging or container images. See `config/excluded.md`.
- Some projects needed extra system tools (`protoc`, `mise`, `clang`, `libbtrfs-dev`, `uv`, `gh`). See `config/system_deps.md`.
- Results come from one VM and one architecture (x86_64) and may not generalize.
