"""Trace the first ordinary XPalm trajectory after the matched measurement job."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess

root = Path(os.environ["GITHUB_WORKSPACE"])
temp = Path(os.environ["RUNNER_TEMP"])
candidate = temp / "matched-xpalm" / "candidate"
matched = temp / "xpalm-results"
out = temp / "xpalm-cold"
out.mkdir()
recipe = root / "cold-tools" / ".ci" / "xpalm-profile"

def read(path):
    return json.loads(path.read_bytes())

def revision(path):
    return subprocess.check_output(["git", "-C", path, "rev-parse", "HEAD"], text=True).strip()

def file_digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()

# Reuse the original phase markers, FD3 pipe and scientific observer.
assert revision(root / "cold-tools") == "d57383775167beb952e0b45bcd1edc25fc85f620"
comparison = read(matched / "comparison.json")
assert revision(candidate / "PlantSimEngine") == comparison["revisions"]["candidate"]
assert revision(candidate / "XPalm") == comparison["xpalm"]
for name in ("Project.toml", "Manifest.toml"):
    assert file_digest(candidate / "environment" / name) == file_digest(root / ".ci/xpalm-matched/environment" / name)

spec = importlib.util.spec_from_file_location("xpalm_profile", recipe / "run.py")
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)
profile.OUT = out
profile.RECIPE = Path(__file__).resolve().parent
summary = profile.trace_process(candidate / "environment", "cold",
    str(recipe / "cold_driver.jl"), str(out), "candidate")

reference = read(matched / "main.json")["rows"][0]["science"]
assert read(out / "candidate-cold.json")["science"] == reference
expected = {"construction", "preparation", "first_full_execution"}
markers = summary["marker_snapshot"]["marker_counts"]
assert {m["phase"] for m in markers} == expected
assert all(m["events"] == {"before": 1, "after": 1} for m in markers)
assert summary["phase_boundary_mismatches"] == 0 and not summary["open_phase_labels_at_eof"]
assert {r["phase"] for r in summary["longest_completed_entries_by_phase"] if r["kind"] == "phase"} == expected
assert not summary["signature_text_recorded"]
(out / "qualification.json").write_text(json.dumps({
    "pse": comparison["revisions"]["candidate"], "xpalm": comparison["xpalm"],
    "matched_main_science": reference, "phase_markers": markers,
    "filter_sha256": file_digest(profile.RECIPE / "cold_trace_filter.py"),
}, indent=2))
