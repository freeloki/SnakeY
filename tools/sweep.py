#!/usr/bin/env python3
"""F3-3 parameter sweep driver (reward and epsilon), reproducible.

Runs tools/train_ai.gd for every (parameter set, seed) of a stage in parallel,
then summarises. Final candidates are re-measured on levels 1-5 with
tools/eval_ai.gd. Python 3 stdlib only.

Never touches the real user:// folder: every Godot process gets APPDATA pointed
at a throwaway folder (as tools/run_smoke.sh does), so even Godot's own log
file goes there. APPDATA redirection only isolates on Windows; on Linux/macOS
point XDG_DATA_HOME / HOME elsewhere before running. The only files written are under tools/out/sweep_F3-3/.

Usage (from the project root, GODOT must point at the console build):
  python tools/sweep.py run coarse  [--jobs 12]
  python tools/sweep.py run fine    [--jobs 12]
  python tools/sweep.py run confirm [--jobs 12]
  python tools/sweep.py levels      [--jobs 12]   # eval_ai L1-5 on confirm brains
  python tools/sweep.py summary coarse|fine|confirm|levels

Runs whose report already exists are skipped, so an interrupted stage resumes.
Every run is deterministic (train_ai seed rule), so a rerun gives the same numbers.

Statistics: each (set, seed) is one sample. A set is compared with the
baseline by Welch's t interval on per-seed win %, df by Welch-Satterthwaite.
Pooled Wilson intervals are also printed, but they ignore seed-to-seed
spread and are therefore too narrow for "is A better than B" questions.
"""

import argparse
import concurrent.futures as cf
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "tools", "out", "sweep_F3-3")

# ---------------------------------------------------------------------------
# Plan
# ---------------------------------------------------------------------------

BASE = {}  # empty overrides = SnakeBrain defaults

# Coarse: one factor at a time around the defaults.
# Defaults: alpha 0.2, gamma 0.9, eps 0.35 -> 0.06 (decay 0.992/match),
# death -60, win 60, food 15, step -0.05, shaping +-0.15.
COARSE_SETS = {
    "base": BASE,
    "alpha=0.05": {"alpha": 0.05},
    "alpha=0.1": {"alpha": 0.1},
    "alpha=0.4": {"alpha": 0.4},
    "gamma=0.7": {"gamma": 0.7},
    "gamma=0.8": {"gamma": 0.8},
    "gamma=0.95": {"gamma": 0.95},
    "gamma=0.99": {"gamma": 0.99},
    "eps_start=0.1": {"epsilon_start": 0.1},
    "eps_start=0.6": {"epsilon_start": 0.6},
    "eps_start=1.0": {"epsilon_start": 1.0},
    "eps_decay=0.98": {"epsilon_decay": 0.98},
    "eps_decay=0.997": {"epsilon_decay": 0.997},
    "eps_decay=0.999": {"epsilon_decay": 0.999},
    "eps_min=0.0": {"epsilon_min": 0.0},
    "eps_min=0.02": {"epsilon_min": 0.02},
    "eps_min=0.12": {"epsilon_min": 0.12},
    "death=-20": {"death_reward": -20.0},
    "death=-150": {"death_reward": -150.0},
    "win=0": {"win_reward": 0.0},
    "win=150": {"win_reward": 150.0},
    "food=5": {"food_reward": 5.0},
    "food=40": {"food_reward": 40.0},
    "step=0": {"step_penalty": 0.0},
    "step=-0.5": {"step_penalty": -0.5},
    "shaping=0": {"shaping_bonus": 0.0, "shaping_penalty": 0.0},
    "shaping=0.5": {"shaping_bonus": 0.5, "shaping_penalty": -0.5},
}

# Fine: chosen from the coarse summary (see docs/sweeps/F3-3.md). Coarse leaders
# were step=-0.5, gamma=0.7, alpha=0.05 (each alone within or near noise), so the
# fine stage brackets them and tries their combinations on new seeds.
FINE_SETS = {
    "base": BASE,
    "gamma=0.6": {"gamma": 0.6},
    "gamma=0.7": {"gamma": 0.7},
    "step=-0.25": {"step_penalty": -0.25},
    "step=-0.5": {"step_penalty": -0.5},
    "step=-1.0": {"step_penalty": -1.0},
    "alpha=0.05": {"alpha": 0.05},
    "g0.7+step-0.5": {"gamma": 0.7, "step_penalty": -0.5},
    "g0.7+a0.05": {"gamma": 0.7, "alpha": 0.05},
    "g0.8+step-0.5": {"gamma": 0.8, "step_penalty": -0.5},
    "g0.7+step-0.5+a0.05": {"gamma": 0.7, "step_penalty": -0.5, "alpha": 0.05},
}

# Confirm: finalists on fresh seeds (never used for selection), longer training.
CONFIRM_SETS = {
    "base": BASE,
    "gamma=0.7": {"gamma": 0.7},
    "step=-0.5": {"step_penalty": -0.5},
    "g0.7+step-0.5": {"gamma": 0.7, "step_penalty": -0.5},
    "g0.7+step-0.5+a0.05": {"gamma": 0.7, "step_penalty": -0.5, "alpha": 0.05},
}

MIGRATE_SETS = {
    "base": BASE,
    "g0.7+step-0.5": {"gamma": 0.7, "step_penalty": -0.5},
    "g0.7+step-0.5+a0.05": {"gamma": 0.7, "step_penalty": -0.5, "alpha": 0.05},
}

STAGES = {
    "coarse": {"sets": COARSE_SETS, "seeds": [1, 2, 3, 4, 5], "matches": 2000,
               "eval_every": 250, "eval_matches": 200},
    "fine": {"sets": FINE_SETS, "seeds": [11, 12, 13, 14, 15, 16], "matches": 2000,
             "eval_every": 250, "eval_matches": 200},
    "confirm": {"sets": CONFIRM_SETS, "seeds": list(range(101, 111)), "matches": 3000,
                "eval_every": 500, "eval_matches": 200},
    # Effect on an existing brain: the confirm "base" brain of the same seed
    # (3000 matches with the defaults) keeps learning under each set. Training
    # seed is offset so the continuation does not replay the first matches.
    "migrate": {"sets": MIGRATE_SETS, "seeds": list(range(101, 111)), "matches": 1000,
                "eval_every": 100, "eval_matches": 200, "init_from": ("confirm", "base"),
                "seed_offset": 5000},
}

# Every evaluation uses the same fixed exploration rate: the game's rate for a
# trained default brain (epsilon_min 0.06). This compares Q-tables, not the
# exploration noise of each set. Sets that change epsilon_min are also measured
# at their own rate in the "levels" step.
EVAL_EPSILON = 0.06
EVAL_SEED = 1000
LEVELS = "1-5"
LEVEL_MATCHES = 400
PLATEAU_LAST = 3  # primary metric: mean of the last 3 evaluations


def set_id(name):
    return re.sub(r"[^A-Za-z0-9._-]", "_", name.replace("=", "_"))


def overrides_arg(ov):
    if not ov:
        return []
    return ["--set=" + ",".join("%s=%s" % (k, repr(float(v))) for k, v in sorted(ov.items()))]


# ---------------------------------------------------------------------------
# Running Godot
# ---------------------------------------------------------------------------

def godot():
    g = os.environ.get("GODOT", "")
    if not g or not os.path.exists(g):
        sys.exit("GODOT is unset or does not exist: '%s'" % g)
    return g


def run_isolated(args, log_path):
    """Runs Godot with user:// redirected to a temp folder; returns (code, stdout)."""
    iso = tempfile.mkdtemp(prefix="snakey_sweep_")
    try:
        env = dict(os.environ)
        env["APPDATA"] = iso
        os.makedirs(os.path.join(iso, "Godot", "app_userdata", "snakey"), exist_ok=True)
        p = subprocess.run([godot(), "--headless", "--path", ROOT] + args, cwd=ROOT, env=env,
                           capture_output=True, text=True, errors="replace")
        text = p.stdout + "\n--- stderr ---\n" + p.stderr
        with open(log_path, "w", encoding="utf-8") as f:
            f.write(text)
        return p.returncode, text
    finally:
        shutil.rmtree(iso, ignore_errors=True)


def train_job(stage, name, ov, seed, cfg):
    d = os.path.join(OUT, stage)
    os.makedirs(d, exist_ok=True)
    brain = os.path.join(d, "%s_s%d.json" % (set_id(name), seed))
    report = brain[:-5] + "_report.json"
    if os.path.exists(report):
        return name, seed, "skip", 0.0
    t0 = time.time()
    args = ["--script", "res://tools/train_ai.gd", "--", "--level=1",
            "--matches=%d" % cfg["matches"], "--seed=%d" % seed,
            "--eval-every=%d" % cfg["eval_every"], "--eval-matches=%d" % cfg["eval_matches"],
            "--eval-epsilon=%s" % EVAL_EPSILON, "--eval-seed=%d" % EVAL_SEED,
            "--out=" + brain.replace("\\", "/")] + overrides_arg(ov)
    if "init_from" in cfg:
        src_stage, src_set = cfg["init_from"]
        init = os.path.join(OUT, src_stage, "%s_s%d.json" % (set_id(src_set), seed))
        args.append("--init-brain=" + init.replace("\\", "/"))
        args[args.index("--seed=%d" % seed)] = "--seed=%d" % (seed + cfg.get("seed_offset", 0))
    code, text = run_isolated(args, brain[:-5] + ".log")
    ok = code == 0 and "TRAIN GECTI" in text and os.path.exists(report)
    return name, seed, "ok" if ok else "FAIL(%d)" % code, time.time() - t0


def cmd_run(stage, jobs):
    cfg = STAGES[stage]
    tasks = [(stage, n, ov, s, cfg) for n, ov in cfg["sets"].items() for s in cfg["seeds"]]
    t0 = time.time()
    failed = 0
    with cf.ThreadPoolExecutor(max_workers=jobs) as ex:
        for fut in cf.as_completed([ex.submit(train_job, *t) for t in tasks]):
            name, seed, st, dt = fut.result()
            failed += 0 if st in ("ok", "skip") else 1
            print("%-22s seed %3d  %-8s %5.1f s" % (name, seed, st, dt), flush=True)
    print("stage %s: %d runs, %d failed, wall %.1f s" % (stage, len(tasks), failed, time.time() - t0))
    return 1 if failed else 0


def levels_job(name, seed, eps_tag, eps):
    d = os.path.join(OUT, "levels")
    os.makedirs(d, exist_ok=True)
    brain = os.path.join(OUT, "confirm", "%s_s%d.json" % (set_id(name), seed))
    dest = os.path.join(d, "%s_s%d_%s.json" % (set_id(name), seed, eps_tag))
    if os.path.exists(dest):
        return name, seed, eps_tag, "skip", 0.0
    t0 = time.time()
    # A player-model path that does not exist = measure without a player model.
    args = ["--script", "res://tools/eval_ai.gd", "--", "--levels=" + LEVELS,
            "--matches=%d" % LEVEL_MATCHES, "--seed=%d" % EVAL_SEED, "--epsilon=%s" % eps,
            "--brain=" + brain.replace("\\", "/"),
            "--player-model=res://tools/out/sweep_F3-3/no_player_model.json"]
    code, text = run_isolated(args, dest[:-5] + ".log")
    m = re.search(r"^JSON: (.+)$", text, re.M)
    if code != 0 or not m:
        return name, seed, eps_tag, "FAIL(%d)" % code, time.time() - t0
    src = m.group(1).strip()
    with open(src, encoding="utf-8") as f:
        doc = json.load(f)
    # eval_ai names files by the second; guard against a parallel overwrite.
    if os.path.normcase(os.path.abspath(doc["config"]["brain"])) != os.path.normcase(os.path.abspath(brain)) \
            or abs(doc["config"]["epsilon"] - eps) > 1e-9:
        return name, seed, eps_tag, "FAIL(output clash, rerun)", time.time() - t0
    shutil.move(src, dest)
    return name, seed, eps_tag, "ok", time.time() - t0


def levels_tasks():
    tasks = []
    for n, ov in CONFIRM_SETS.items():
        for s in STAGES["confirm"]["seeds"]:
            tasks.append((n, s, "eps0.06", EVAL_EPSILON))
            own = ov.get("epsilon_min")
            if own is not None and abs(own - EVAL_EPSILON) > 1e-9:
                tasks.append((n, s, "epsown", own))
    return tasks


def cmd_levels(jobs):
    tasks = levels_tasks()
    t0 = time.time()
    failed = 0
    with cf.ThreadPoolExecutor(max_workers=jobs) as ex:
        futs = []
        for t in tasks:
            futs.append(ex.submit(levels_job, *t))
            time.sleep(0.3)  # spread start times, eval_ai output names are per second
        for fut in cf.as_completed(futs):
            name, seed, tag, st, dt = fut.result()
            failed += 0 if st in ("ok", "skip") else 1
            print("%-22s seed %3d %-7s %-10s %5.1f s" % (name, seed, tag, st, dt), flush=True)
    print("levels: %d runs, %d failed, wall %.1f s" % (len(tasks), failed, time.time() - t0))
    return 1 if failed else 0


# ---------------------------------------------------------------------------
# Statistics
# ---------------------------------------------------------------------------

# Two-sided 95% t critical values.
_T95 = {1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571, 6: 2.447, 7: 2.365, 8: 2.306,
        9: 2.262, 10: 2.228, 12: 2.179, 14: 2.145, 16: 2.120, 18: 2.101, 20: 2.086,
        25: 2.060, 30: 2.042, 40: 2.021, 60: 2.000, 120: 1.980}


def t95(df):
    df = max(1, int(math.floor(df)))
    keys = sorted(_T95)
    for k in reversed(keys):
        if df >= k:
            return _T95[k]
    return _T95[1]


def mean(x):
    return sum(x) / len(x)


def sd(x):
    if len(x) < 2:
        return 0.0
    m = mean(x)
    return math.sqrt(sum((v - m) ** 2 for v in x) / (len(x) - 1))


def welch(a, b):
    """95% CI of mean(a) - mean(b)."""
    va, vb = sd(a) ** 2 / len(a), sd(b) ** 2 / len(b)
    se = math.sqrt(va + vb)
    d = mean(a) - mean(b)
    if se == 0:
        return d, d, d
    df = (va + vb) ** 2 / ((va ** 2) / (len(a) - 1) + (vb ** 2) / (len(b) - 1))
    h = t95(df) * se
    return d, d - h, d + h


def wilson(k, n, z=1.96):
    if n == 0:
        return 0.0, 0.0
    p = k / n
    den = 1 + z * z / n
    c = (p + z * z / (2 * n)) / den
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / den
    return 100 * (c - h), 100 * (c + h)


# ---------------------------------------------------------------------------
# Summaries
# ---------------------------------------------------------------------------

def load_stage(stage):
    cfg = STAGES[stage]
    data = {}
    for n in cfg["sets"]:
        runs = []
        for s in cfg["seeds"]:
            p = os.path.join(OUT, stage, "%s_s%d_report.json" % (set_id(n), s))
            if os.path.exists(p):
                with open(p, encoding="utf-8") as f:
                    runs.append(json.load(f))
        data[n] = runs
    return data


def summarize_train(stage):
    data = load_stage(stage)
    base = data.get("base", [])

    def plateau(r):
        ev = r["evals"][-PLATEAU_LAST:]
        return mean([e["levels"][0]["win_pct"] for e in ev])

    def at(r, k):
        for e in r["evals"]:
            if e["after_matches"] == k:
                return e["levels"][0]["win_pct"]
        return float("nan")

    base_pl = [plateau(r) for r in base]
    rows = []
    for n, runs in data.items():
        if not runs:
            continue
        pl = [plateau(r) for r in runs]
        causes = {}
        nmatch = 0
        for r in runs:
            lv = r["evals"][-1]["levels"][0]
            nmatch += lv["matches"]
            for c, v in lv["death_causes_trained"].items():
                causes[c] = causes.get(c, 0) + v
        d, lo, hi = welch(pl, base_pl) if n != "base" and len(base_pl) > 1 else (0.0, 0.0, 0.0)
        rows.append({
            "set": n, "seeds": len(runs), "plateau": mean(pl), "sd": sd(pl),
            "w250": mean([at(r, 250) for r in runs]), "w500": mean([at(r, 500) for r in runs]),
            "w1000": mean([at(r, 1000) for r in runs]),
            "final": mean([r["evals"][-1]["levels"][0]["win_pct"] for r in runs]),
            "d": d, "lo": lo, "hi": hi, "sig": n != "base" and (lo > 0 or hi < 0),
            "self": 100 * causes.get("self", 0) / nmatch, "wall": 100 * causes.get("wall", 0) / nmatch,
            "head_on": 100 * causes.get("head_on", 0) / nmatch,
            "train_s": mean([r["run"]["train_seconds"] for r in runs]),
        })
    rows.sort(key=lambda r: -r["plateau"])
    print("stage %s: plateau = mean win %% of the last %d evals (L1, %d matches each, eps %.2f, eval seed %d)"
          % (stage, PLATEAU_LAST, STAGES[stage]["eval_matches"], EVAL_EPSILON, EVAL_SEED))
    print("| Set | Seed | Plato % | sd | @250 | @500 | @1000 | Son | Fark vs baz [95% GA] | Anlamli | Kendi % | Duvar % | Kafa % | Egitim sn |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in rows:
        diff = "-" if r["set"] == "base" else "%+.1f [%+.1f, %+.1f]" % (r["d"], r["lo"], r["hi"])
        print("| %s | %d | %.1f | %.1f | %.1f | %.1f | %.1f | %.1f | %s | %s | %.1f | %.1f | %.1f | %.1f |" % (
            r["set"], r["seeds"], r["plateau"], r["sd"], r["w250"], r["w500"], r["w1000"], r["final"],
            diff, "evet" if r["sig"] else "hayir", r["self"], r["wall"], r["head_on"], r["train_s"]))
    with open(os.path.join(OUT, "summary_%s.json" % stage), "w", encoding="utf-8") as f:
        json.dump(rows, f, indent=1)


def summarize_levels():
    d = os.path.join(OUT, "levels")
    per = {}  # (set, tag) -> level -> [win% per seed]; also pooled counts
    for n in CONFIRM_SETS:
        for s in STAGES["confirm"]["seeds"]:
            for tag in ("eps0.06", "epsown"):
                p = os.path.join(d, "%s_s%d_%s.json" % (set_id(n), s, tag))
                if not os.path.exists(p):
                    continue
                with open(p, encoding="utf-8") as f:
                    doc = json.load(f)
                for res in doc["results"]:
                    e = per.setdefault((n, tag), {}).setdefault(res["level"], {"w": [], "k": 0, "n": 0, "c": {}})
                    e["w"].append(100.0 * res["wins"] / res["matches"])
                    e["k"] += res["wins"]
                    e["n"] += res["matches"]
    print("levels: eval_ai L%s, %d matches/level/seed, eval seed %d, confirm brains (%d seeds)"
          % (LEVELS, LEVEL_MATCHES, EVAL_SEED, len(STAGES["confirm"]["seeds"])))
    print("| Set | eps | Seviye | Kazanma % (seed ort.) | sd | Havuz Wilson 95% | Fark vs baz [95% GA, Welch] |")
    print("|---|---|---|---|---|---|---|")
    base = per.get(("base", "eps0.06"), {})
    out = []
    for (n, tag), lv in per.items():
        for L in sorted(lv):
            e = lv[L]
            lo, hi = wilson(e["k"], e["n"])
            diff = "-"
            if n != "base" and L in base:
                dd, a, b = welch(e["w"], base[L]["w"])
                diff = "%+.1f [%+.1f, %+.1f]%s" % (dd, a, b, " *" if (a > 0 or b < 0) else "")
            print("| %s | %s | %d | %.1f | %.1f | %.1f-%.1f | %s |" % (n, tag, L, mean(e["w"]), sd(e["w"]), lo, hi, diff))
            out.append({"set": n, "eps": tag, "level": L, "mean": mean(e["w"]), "sd": sd(e["w"]),
                        "wilson": [lo, hi], "seeds": len(e["w"])})
        # all 5 levels together, per seed
        seeds = len(next(iter(lv.values()))["w"])
        allw = [mean([lv[L]["w"][i] for L in lv]) for i in range(seeds)]
        diff = "-"
        if n != "base" and base:
            bw = [mean([base[L]["w"][i] for L in base]) for i in range(len(next(iter(base.values()))["w"]))]
            dd, a, b = welch(allw, bw)
            diff = "%+.1f [%+.1f, %+.1f]%s" % (dd, a, b, " *" if (a > 0 or b < 0) else "")
        print("| %s | %s | 1-5 | %.1f | %.1f | - | %s |" % (n, tag, mean(allw), sd(allw), diff))
    # Death causes and scores of the trained snake, pooled over levels and seeds.
    print()
    print("| Set | eps | Mac | Skor (AI-rakip) | Kendi % | Duvar % | Kafa kafaya % | Rakip govdesi % | Sure doldu % | Hayatta % |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for n in CONFIRM_SETS:
        for tag in ("eps0.06", "epsown"):
            c, tot, st, sr = {}, 0, 0.0, 0.0
            for s in STAGES["confirm"]["seeds"]:
                p = os.path.join(d, "%s_s%d_%s.json" % (set_id(n), s, tag))
                if not os.path.exists(p):
                    continue
                with open(p, encoding="utf-8") as f:
                    for res in json.load(f)["results"]:
                        tot += res["matches"]
                        st += res["avg_score_trained"] * res["matches"]
                        sr += res["avg_score_rival"] * res["matches"]
                        for k, v in res["death_causes_trained"].items():
                            c[k] = c.get(k, 0) + v
            if tot:
                pc = lambda k: 100.0 * c.get(k, 0) / tot
                print("| %s | %s | %d | %.2f-%.2f | %.1f | %.1f | %.1f | %.1f | %.1f | %.1f |" % (
                    n, tag, tot, st / tot, sr / tot, pc("self"), pc("wall") + pc("barrier"), pc("head_on"),
                    pc("other_snake_body"), pc("time_up"), pc("survived")))
    with open(os.path.join(OUT, "summary_levels.json"), "w", encoding="utf-8") as f:
        json.dump(out, f, indent=1)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("stage", choices=sorted(STAGES))
    r.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) - 4))
    lv = sub.add_parser("levels")
    lv.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) - 4))
    s = sub.add_parser("summary")
    s.add_argument("stage", choices=sorted(STAGES) + ["levels"])
    a = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    if a.cmd == "run":
        sys.exit(cmd_run(a.stage, a.jobs))
    if a.cmd == "levels":
        sys.exit(cmd_levels(a.jobs))
    if a.stage == "levels":
        summarize_levels()
    else:
        summarize_train(a.stage)


if __name__ == "__main__":
    main()
