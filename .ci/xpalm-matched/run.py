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
    "before": "f746e9343155f49308d5d9b3a6e2fd51bdcf3ce3",
    "candidate": "3b03f0ab82a80e812a19806ecf3fffe86b569197",
}
xpalm_revision = "f44f728dd68e804ffa6bcb872e5b873ce46bf3b5"


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
    checkout(root / "public-mtg", arm / "MultiScaleTreeGraph", "bcc58a86356d0cbdcafbac721a367e7dcb978fdb")
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
    for pkg in ("XPalm", "MultiScaleTreeGraph"):
        assert not git_text(arm/pkg, "status", "--porcelain", "--untracked-files=no")
    reports[role] = json.loads((results / f"{role}.json").read_text())

reference = json.loads((recipe / "reference.json").read_text())
anchor = reports["main"]["rows"][0]["science"]
summary = {"revisions": revisions, "xpalm": xpalm_revision, "mtg": "bcc58a86356d0cbdcafbac721a367e7dcb978fdb", "cpu": reports["main"]["cpu"],
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

