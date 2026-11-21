import hashlib
import json
import os
from pathlib import Path
import shutil
from statistics import median
import subprocess
import sys
import tomllib

root = Path(os.environ["GITHUB_WORKSPACE"])
recipe = Path(__file__).resolve().parent
workspace = Path(os.environ["RUNNER_TEMP"]) / "matched-xpalm"
workspace.mkdir()
results = Path(os.environ["RUNNER_TEMP"]) / "xpalm-results"
results.mkdir()
revisions = {
    "main": "8d1f8484c8ad68cc5da8004209b2062070cac28a",
    "historical": "cd5517551f4cd4cf01504cb312e2b81f6fabe6ba",
    "candidate": "7bab6b3ca6b8520ee82ffb1eafff213b8058f2f1",
}
scenario, = sys.argv[1:]
xpalm_revision = {
    "legacy": "5795bb0984516830c3ffb6fd1d2ca57f54f9e8cd",
    "modern": "f44f728dd68e804ffa6bcb872e5b873ce46bf3b5",
}[scenario]
mtg_revision = "b3b39f5d33543fe2775756782ec1c4de33ba5775"
prior = json.loads((recipe / "prior-linux-main.json").read_text())[scenario]


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


def install_manifest(env, source):
    # Pkg needs the package extension triggers declared by this revision of PSE.
    path = env / "Manifest.toml"
    text = path.read_text()
    project = tomllib.loads((source / "Project.toml").read_text())
    expected = tomllib.loads(text)
    entry, = expected["deps"]["PlantSimEngine"]
    assert set(entry["deps"]) == set(project["deps"])
    assert entry["uuid"] == project["uuid"] and entry["version"] == project["version"]
    start = text.index("    [deps.PlantSimEngine.extensions]")
    stop = text.index("[[deps.", start)
    lines = []
    for key in ("extensions", "weakdeps"):
        entry[key] = project.get(key, {})
        lines.append(f"    [deps.PlantSimEngine.{key}]")
        lines.extend(f"    {k} = {json.dumps(v)}" for k, v in sorted(entry[key].items()))
        lines.append("")
    text = text[:start] + "\n".join(lines) + "\n" + text[stop:]
    assert tomllib.loads(text) == expected
    path.write_text(text)


def prepare_role(role, revision):
    arm = workspace / role
    arm.mkdir()
    checkout(root, arm / "PlantSimEngine", revision)
    checkout(root / "public-xpalm", arm / "XPalm", xpalm_revision)
    checkout(root / "public-mtg", arm / "MultiScaleTreeGraph", mtg_revision)
    if scenario == "legacy":
        patch = recipe / "xpalm-743f.diff"
        assert digest(patch) == "743f931fbb9d6208a6c46b42b11180fba210b5fb09af58912749002ce675a61f"
        run("git", "apply", "--check", "--index", str(patch), cwd=arm / "XPalm")
        run("git", "apply", "--index", str(patch), cwd=arm / "XPalm")
    tree = git_text(arm / "XPalm", "write-tree")
    env = arm / "environment"
    shutil.copytree(recipe / "environment", env)
    install_manifest(env, arm / "PlantSimEngine")
    pinned = {n: digest(env / n) for n in ("Project.toml", "Manifest.toml")}
    run(*command(env, "-e", "using Pkg; Pkg.instantiate(; allow_autoprecomp=false)"))
    assert all(digest(env / n) == h for n, h in pinned.items())
    provenance[role] = dict(pse=revision, xpalm=xpalm_revision, xpalm_tree=tree, mtg=mtg_revision, files=pinned)
    (results / "sources.json").write_text(json.dumps(provenance, indent=2) + "\n")
    return arm, env


def run_role(role, revision, reference_path):
    arm, env = prepare_role(role, revision)
    print(f"::group::{scenario} {role} {revision}", flush=True)
    run(*command(env, str(recipe / "compare.jl"), str(results), role, str(reference_path)))
    print("::endgroup::", flush=True)
    assert all(digest(env / n) == h for n, h in provenance[role]["files"].items())
    assert not git_text(arm / "PlantSimEngine", "status", "--porcelain", "--untracked-files=no")
    assert not git_text(arm / "MultiScaleTreeGraph", "status", "--porcelain", "--untracked-files=no")
    assert not git_text(arm / "XPalm", "diff", "--name-only")
    assert git_text(arm / "XPalm", "write-tree") == provenance[role]["xpalm_tree"]


def previous_linux_check(science, cpu, julia_commit):
    assert julia_commit == prior["julia_commit"] and prior["replays"] == 8
    observed = prior["science"]
    assert all(science[k] == observed[k] for k in ("objects", "retained_samples"))
    assert all(science["components"][k] == observed["components"][k]
               for k in ("step", "rngs", "topology", "source_topology"))
    equal = {k: science[k] == observed[k] for k in observed}
    if cpu == prior["cpu"]:
        assert all(equal.values()), "Fresh main differs from its archived Linux runs on the same CPU"
    return dict(cpu=prior["cpu"], archive=prior["archive_sha256"], equality=equal)


provenance = {}


def main():
    # Independent scientific observations for the original and revised XPalm.
    # Generate a second Linux witness from main's two existing warm trajectories.
    reference_path = recipe / ("modern-independent-mac.json" if scenario == "modern" else "reference.json")
    if scenario == "modern":
        assert digest(reference_path) == "975b70696fbfa690e8da26a5a1bb3ad40c11d89c25d7627079e2f6f85561b810"
    reference = json.loads(reference_path.read_text())
    assert len(reference["object_counts"]) == 4161
    assert reference["growth_days"] + reference["ordinary_days"] == 4160
    assert reference["objects"] == reference["object_counts"][-1]
    reference_digest = digest(reference_path)
    reports = {}
    for role, revision in revisions.items():
        run_role(role, revision, reference_path)
        assert digest(reference_path) == reference_digest
        reports[role] = json.loads((results / f"{role}.json").read_text())
    assert len({p["xpalm_tree"] for p in provenance.values()}) == 1
    anchor = reports["main"]["rows"][0]["science"]
    summary = {"scenario": scenario, "reference_sha256": reference_digest, "revisions": revisions, "xpalm": xpalm_revision, "mtg": "b3b39f5d33543fe2775756782ec1c4de33ba5775", "cpu": reports["main"]["cpu"],
               "reference_core_equal": anchor["core"] == reference["core"],
               "reference_companion_equal": anchor["companion_digest"] == reference["companion_digest"],
               "reference_component_equality": {k: v == reference["components"][k] for k, v in anchor["components"].items()},
               "arms": {}}
    summary["previous_linux"] = previous_linux_check(anchor, reports["main"]["cpu"], reports["main"]["julia_commit"])
    assert all(summary["reference_component_equality"][k] for k in ("step", "rngs", "topology", "source_topology"))
    linux_reference = json.loads((results / "main-linux-reference.json").read_text())
    assert (linux_reference["pse"], linux_reference["xpalm"], linux_reference["mtg"]) == (revisions["main"], xpalm_revision, mtg_revision)
    assert linux_reference["object_counts"] == reference["object_counts"]
    assert (linux_reference["growth_days"], linux_reference["ordinary_days"]) == (reference["growth_days"], reference["ordinary_days"])
    assert all(anchor[k] == linux_reference[k] for k in anchor)
    summary["linux_reference_sha256"] = digest(results / "main-linux-reference.json")
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
        assert all(v["swap_in"] == v["swap_out"] == 0 for v in summary["arms"][role]["vm_counter_deltas"])
        print(role, {k: median(v) for k, v in summary["arms"][role].items() if k != "vm_counter_deltas"})
    (results / "comparison.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))



if __name__ == "__main__":
    main()
