import hashlib
import json
import os
from pathlib import Path
import shutil
from statistics import median
import subprocess

root = Path(os.environ["GITHUB_WORKSPACE"])
recipe = Path(__file__).resolve().parent
workspace = Path(os.environ["RUNNER_TEMP"]) / "matched-xpalm"
workspace.mkdir()
results = Path(os.environ["RUNNER_TEMP"]) / "xpalm-results"
results.mkdir()
revisions = {
    "main": "8d1f8484c8ad68cc5da8004209b2062070cac28a",
    "historical": "cd5517551f4cd4cf01504cb312e2b81f6fabe6ba",
    "before": "30b9a080efde14d50378bd40aa9c027563cceaa0",
    "candidate": "bda0b81920c7351c3ec25c2b09f45abdd371e347",
}
xpalm_revision = "5795bb0984516830c3ffb6fd1d2ca57f54f9e8cd"


def run(*args, cwd=None):
    subprocess.run(args, cwd=cwd, check=True)


def git_text(cwd, *args):
    return subprocess.check_output(["git", *args], cwd=cwd, text=True).strip()


def checkout(source, dest, revision):
    run("git", "clone", "--quiet", "--shared", "--no-checkout", str(source), str(dest))
    run("git", "checkout", "--quiet", "--detach", revision, cwd=dest)
    assert git_text(dest, "rev-parse", "HEAD") == revision


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def command(project, *args):
    return ("julia", "--startup-file=no", "--threads=1,1", "--gcthreads=1", f"--project={project}", *args)


reports = {}
for role, revision in revisions.items():
    arm = workspace / role
    arm.mkdir()
    checkout(root, arm / "PlantSimEngine", revision)
    checkout(root / "public-xpalm", arm / "XPalm", xpalm_revision)
    if role in ("before", "candidate"):
        patch = recipe / "xpalm-743f.diff"
        assert digest(patch) == "743f931fbb9d6208a6c46b42b11180fba210b5fb09af58912749002ce675a61f"
        run("git", "apply", "--check", str(patch), cwd=arm / "XPalm")
        run("git", "apply", str(patch), cwd=arm / "XPalm")
    env = arm / "environment"
    shutil.copytree(recipe / "environment", env)
    pinned = {n: digest(env / n) for n in ("Project.toml", "Manifest.toml")}
    run(*command(env, "-e", "using Pkg; Pkg.instantiate(; allow_autoprecomp=false)"))
    assert all(digest(env / n) == h for n, h in pinned.items())
    print(f"::group::{role} {revision}", flush=True)
    run(*command(env, str(recipe / "compare.jl"), str(results), role))
    print("::endgroup::", flush=True)
    assert all(digest(env / n) == h for n, h in pinned.items())
    assert not git_text(arm / "PlantSimEngine", "status", "--porcelain", "--untracked-files=no")
    reports[role] = json.loads((results / f"{role}.json").read_text())

reference = json.loads((recipe / "reference.json").read_text())
anchor = reports["main"]["rows"][0]["science"]
summary = {"revisions": revisions, "xpalm": xpalm_revision, "cpu": reports["main"]["cpu"],
           "mac_core_equal": anchor["core"] == reference["core"],
           "mac_companion_equal": anchor["companion_digest"] == reference["companion_digest"],
           "mac_component_equality": {k: v == reference["components"][k] for k, v in anchor["components"].items()},
           "arms": {}}
for role, report in reports.items():
    assert (report["cpu"], report["hostname"], report["julia_commit"]) == (
        reports["main"]["cpu"], reports["main"]["hostname"], reports["main"]["julia_commit"])
    assert len(report["rows"]) == 8
    assert all(row["science"] == anchor for row in report["rows"]), f"State, histories, RNG or sharing differ on {role}"
    full = [r for r in report["rows"] if r["phase"] == "measure" and r["mode"] == "full"]
    daily = [r for r in report["rows"] if r["phase"] == "measure" and r["mode"] == "daily"]
    assert len(full) == len(daily) == 3
    summary["arms"][role] = {
        "prepare_s": [r["times"]["preparation"]["seconds"] for r in full],
        "construct_s": [r["times"]["construction"]["seconds"] for r in full],
        "continuous_s": [r["times"]["execution"]["seconds"] for r in full],
        "continuous_bytes": [r["times"]["execution"]["bytes"] for r in full],
        "growth_s": [r["growth_seconds"] for r in daily],
        "ordinary_s": [r["ordinary_seconds"] for r in daily],
        "vm_counter_deltas": [{k: r["after"][k] - r["before"][k] for k in r["after"]} for r in full + daily],
    }
    print(role, {k: median(v) for k, v in summary["arms"][role].items() if k != "vm_counter_deltas"})
(results / "comparison.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary, indent=2))

