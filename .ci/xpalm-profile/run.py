"""Matched CPU profiling only; no performance verdict from instrumented runs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

REVISIONS = {
    "main": "8d1f8484c8ad68cc5da8004209b2062070cac28a",
    "historical": "cd5517551f4cd4cf01504cb312e2b81f6fabe6ba",
    "candidate": "77e60af9f5f030ee1057c916166e99bf7c3e03f2",
}
XPALM = "5795bb0984516830c3ffb6fd1d2ca57f54f9e8cd"
PATCH_SHA = "743f931fbb9d6208a6c46b42b11180fba210b5fb09af58912749002ce675a61f"
ROOT = Path(os.environ["GITHUB_WORKSPACE"])
RECIPE = Path(__file__).resolve().parent
FROZEN = RECIPE.parent / "xpalm-matched"
WORK = Path(os.environ["RUNNER_TEMP"]) / "profile-xpalm-77e60af9"
OUT = Path(os.environ["RUNNER_TEMP"]) / "xpalm-profile-results"


def run(*args, cwd=None, env=None):
    subprocess.run(args, cwd=cwd, env=env, check=True)


def git(cwd, *args):
    return subprocess.check_output(["git", *args], cwd=cwd, text=True).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def command(project, *args):
    flags = () if project is None else (f"--project={project}",)
    return ("julia", "--startup-file=no", "--threads=1,1", "--gcthreads=1", *flags, *args)


def checkout(source, destination, revision):
    run("git", "clone", "--quiet", "--shared", "--no-checkout", str(source), str(destination))
    run("git", "checkout", "--quiet", "--detach", revision, cwd=destination)
    assert git(destination, "rev-parse", "HEAD") == revision


def image(directory):
    # Hash tracked source/data only. Installed caches never become scientific inputs.
    paths = git(directory, "ls-files", "-z").split("\0")
    return {name: digest(directory / name) for name in paths if name}


def guard_recipe():
    receipt = json.loads((ROOT / "FROZEN-RECIPE-FROM-16C.json").read_text())
    assert receipt["source_commit"] == "16c63353472e947d707e7ab3eaa19c760ef3455b"
    assert receipt["all_bytes_exact"] and len(receipt["files"]) == 14
    for entry in receipt["files"]:
        assert digest(ROOT / entry["path"]) == entry["sha256"]
    assert not git(ROOT, "diff", REVISIONS["candidate"], "HEAD", "--", "src", "ext", "Project.toml")


def verify_arm(role, provenance):
    arm = WORK / role
    assert git(arm / "PlantSimEngine", "rev-parse", "HEAD") == REVISIONS[role]
    assert not git(arm / "PlantSimEngine", "status", "--porcelain", "--untracked-files=no")
    assert git(arm / "XPalm", "rev-parse", "HEAD") == XPALM
    assert image(arm / "PlantSimEngine") == provenance["PSE_files"]
    assert image(arm / "XPalm") == provenance["XPalm_files"]
    for name, sha in provenance["lock_sha256"].items():
        assert digest(arm / "environment" / name) == sha


def trace_process(project, prefix, *arguments):
    """FD3 is a pipe: signatures are drained, never persisted as a raw file."""
    env = os.environ.copy()
    env.update(TRACE_FILTER=str(RECIPE / "cold_trace_filter.py"),
               TRACE_RECORDS=str(OUT / (prefix + "-compile.jsonl")),
               TRACE_SUMMARY=str(OUT / (prefix + "-compile-summary.json")))
    shell = '''set -u
exec 3> >(python3 "$TRACE_FILTER" --records "$TRACE_RECORDS" --summary "$TRACE_SUMMARY")
trace_filter=$!
set +e
"$@"
science_status=$?
exec 3>&-
wait "$trace_filter"
filter_status=$?
set -e
test "$science_status" -eq 0
test "$filter_status" -eq 0
'''
    run("bash", "-c", shell, "xpalm-cold-fd3",
        *command(project, "--trace-compile=/dev/fd/3", "--trace-compile-timing", *arguments), env=env)
    summary = json.loads((OUT / (prefix + "-compile-summary.json")).read_text())
    assert summary["signature_text_recorded"] is False
    assert summary["written_bytes"] <= summary["record_byte_limit"]
    return summary


def profiles():
    guard_recipe()
    WORK.mkdir()
    OUT.mkdir()
    # Both standard Profile and the FD3 relay are checked before a long process.
    smoke = ('using Profile; Profile.init(;n=100000,delay=0.001); '
             'probe(n)=sum(sqrt(Float64(i)) for i in 1:n); '
             'Profile.@profile probe(10000); @assert probe(10)>0; '
             'println("PROFILE_FD3_SMOKE_OK")')
    summary = trace_process(None, "smoke", "-e", smoke)
    assert summary["completed_records"] > 0
    run(*command(None, str(RECIPE / "selftest.jl")))
    provenance = {}
    for role, revision in REVISIONS.items():
        arm = WORK / role
        arm.mkdir()
        checkout(ROOT, arm / "PlantSimEngine", revision)
        checkout(ROOT / "public-xpalm", arm / "XPalm", XPALM)
        if role == "candidate":
            patch = FROZEN / "xpalm-743f.diff"
            assert digest(patch) == PATCH_SHA
            run("git", "apply", "--check", str(patch), cwd=arm / "XPalm")
            run("git", "apply", str(patch), cwd=arm / "XPalm")
        environment = arm / "environment"
        shutil.copytree(FROZEN / "environment", environment)
        provenance[role] = {"revision": revision, "xpalm": XPALM,
            "PSE_files": image(arm / "PlantSimEngine"), "XPalm_files": image(arm / "XPalm"),
            "lock_sha256": {name: digest(environment / name) for name in ("Project.toml", "Manifest.toml")}}
        run(*command(environment, "-e", 'using Pkg; isempty(Pkg.Registry.reachable_registries()) && '
            'Pkg.Registry.add("General"); Pkg.instantiate(;allow_autoprecomp=false)'))
        verify_arm(role, provenance[role])
        print(f"::group::CPU profile {role} {revision}", flush=True)
        run(*command(environment, str(RECIPE / "profile_driver.jl"), str(OUT), role))
        print("::endgroup::", flush=True)
        verify_arm(role, provenance[role])
        (OUT / "source-provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    reports = {role: json.loads((OUT / (role + ".json")).read_text()) for role in REVISIONS}
    anchor = reports["main"]["rows"][0]["science"]
    machine = tuple(reports["main"][field] for field in ("cpu", "hostname", "julia_commit"))
    for role, report in reports.items():
        assert tuple(report[field] for field in ("cpu", "hostname", "julia_commit")) == machine
        assert len(report["rows"]) == 4
        assert all(row["science"] == anchor for row in report["rows"]), f"Scientific/aliasing mismatch: {role}"
        for mode in ("ordinary", "growth"):
            assert (OUT / f"{role}-{mode}-profile.json").is_file()
    qualified = {"revisions": REVISIONS, "xpalm": XPALM, "trajectories": 12,
                 "same_runner": True, "all_science_equal": True, "timings_instrumented": True,
                 "performance_verdict": None, "anchor": anchor}
    (OUT / "profiles-qualified.json").write_text(json.dumps(qualified, indent=2) + "\n")
    guard_recipe()


def cold():
    guard_recipe()
    qualified = json.loads((OUT / "profiles-qualified.json").read_text())
    assert qualified["all_science_equal"] and qualified["trajectories"] == 12
    provenance = json.loads((OUT / "source-provenance.json").read_text())
    verify_arm("candidate", provenance["candidate"])
    trace_process(WORK / "candidate/environment", "cold",
                  str(RECIPE / "cold_driver.jl"), str(OUT), "candidate")
    report = json.loads((OUT / "candidate-cold.json").read_text())
    assert report["science"] == qualified["anchor"], "Cold candidate scientific/aliasing mismatch"
    verify_arm("candidate", provenance["candidate"])
    guard_recipe()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=("profiles", "cold"))
    selected = parser.parse_args().stage
    profiles() if selected == "profiles" else cold()
