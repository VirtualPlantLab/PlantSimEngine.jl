"""Summarize immutable ordinary-engine checkpoints and quiet-window receipts."""
import argparse
import hashlib
import json
import math
import statistics
from datetime import datetime
from pathlib import Path

PHASES = ("construction", "preparation", "execution")
SAMPLES = 3
QUIET_RECEIPTS = 8


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_checkpoint(path):
    raw = path.read_bytes()
    return json.loads(raw), hashlib.sha256(raw).hexdigest()


def finite_nonnegative(value, name):
    require(isinstance(value, (int, float)) and not isinstance(value, bool)
            and math.isfinite(value) and value >= 0, f"invalid {name}: {value!r}")
    return value


def timestamp(value):
    parsed = datetime.fromisoformat(value)
    require(parsed.utcoffset() is not None, "quiet timestamps need an explicit timezone")
    return finite_nonnegative(parsed.timestamp(), "quiet timestamp")


def case_label(case):
    require(case["arm"] in ("baseline", "candidate"), "unknown benchmark arm")
    require(case["kind"] in ("xpalm", "maespa"), "unknown benchmark kind")
    require(case["mode"] in ("none", "all"), "unknown output mode")
    return (f"xpalm-{case['size']}-{case['mode']}" if case["kind"] == "xpalm" else
            f"maespa-{case['copies']}-{case['size']}-{case['mode']}")


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def summary(rows):
    require(len(rows) == SAMPLES, f"expected exactly {SAMPLES} measured samples")
    for row in rows:
        finite_nonnegative(row["reachable_simulation_bytes"], "reachable bytes")
        for phase in PHASES:
            for field in ("seconds", "bytes", "gctime", "compile_seconds", "recompile_seconds"):
                finite_nonnegative(row[phase][field], f"{phase}.{field}")
            require(row[phase]["compile_seconds"] == row[phase]["recompile_seconds"] == 0,
                    "measured phase compiled or recompiled")
    result = {phase: {
        "median_seconds": statistics.median(row[phase]["seconds"] for row in rows),
        "min_seconds": min(row[phase]["seconds"] for row in rows),
        "max_seconds": max(row[phase]["seconds"] for row in rows),
        "median_bytes": statistics.median(row[phase]["bytes"] for row in rows),
        "median_gc_seconds": statistics.median(row[phase]["gctime"] for row in rows),
    } for phase in PHASES}
    result["complete"] = {
        "median_seconds": statistics.median(sum(row[phase]["seconds"] for phase in PHASES) for row in rows),
        "median_bytes": statistics.median(sum(row[phase]["bytes"] for phase in PHASES) for row in rows),
    }
    result["reachable_simulation_bytes"] = statistics.median(row["reachable_simulation_bytes"] for row in rows)
    return result


def collect(root, receipts):
    cases = []
    pse_images = {"baseline": set(), "candidate": set()}
    covered = {}
    runtime_fingerprints = set()
    receipt_labels = set()
    require(len(receipts) == QUIET_RECEIPTS, f"expected {QUIET_RECEIPTS} quiet-window receipts")
    for receipt in receipts:
        require(receipt["state"] == "complete" and receipt["all_cases_contained"] is True,
                "incomplete or rejected quiet window")
        stop, resume = receipt["stop"], receipt["continue"]
        require(stop["event"] == "stop" and resume["event"] == "continue", "invalid pause event pair")
        require(stop["pid"] == resume["pid"], "pause event process identities differ")
        label = receipt["configuration"]["label"]
        require(stop["label"] == resume["label"] == label and label not in receipt_labels,
                "pause labels differ or are duplicated")
        receipt_labels.add(label)
        window_start, window_end = timestamp(stop["at"]), timestamp(resume["at"])
        require(window_start <= window_end, "quiet window ends before it starts")
        configured = receipt["configuration"]["cases"]
        expected_keys = [(case["arm"], case["kind"], case_label(case)) for case in configured]
        observed_keys = [(case["arm"], case["kind"], case_label(case)) for case in receipt["cases"]]
        require(expected_keys == observed_keys and len(set(expected_keys)) == len(expected_keys),
                "quiet window does not cover its configured cases exactly in order")
        for expected, case in zip(configured, receipt["cases"]):
            require(all(case.get(field, 1) == expected.get(field, 1)
                        for field in ("arm", "kind", "size", "mode", "copies")),
                    "quiet case configuration differs")
        for case in receipt["cases"]:
            label = case_label(case)
            key = (case["arm"], case["kind"], label)
            require(key not in covered, f"duplicate quiet coverage: {key}")
            require(case["state"] == "complete", f"unfinished interval: {key}")
            started = finite_nonnegative(case["started"], "case start")
            ended = finite_nonnegative(case["ended"], "case end")
            require(window_start <= started <= ended <= window_end,
                    f"case is outside its actual quiet interval: {key}")
            interval = json.loads((root / case["arm"] / case["kind"] / f"{label}-interval.json").read_text())
            require(case == interval, f"quiet receipt and interval checkpoint differ: {key}")
            covered[key] = case
    for kind, labels in (
        ("maespa", [f"maespa-{copies}-{steps}-{mode}" for copies in (1, 4)
                     for steps in (24, 96) for mode in ("none", "all")]),
        ("xpalm", [f"xpalm-{days}-{mode}" for days, mode in
                    ((256, "none"), (256, "all"), (1024, "none"), (4160, "none"))]),
    ):
        for label in labels:
            pair = {}
            artifacts = {}
            for arm in ("baseline", "candidate"):
                key = (arm, kind, label)
                require(key in covered, f"missing quiet coverage: {key}")
                interval = covered[key]
                path = root / arm / kind / f"{label}.json"
                data, checkpoint_sha256 = read_checkpoint(path)
                require(interval["checkpoint_sha256"] == checkpoint_sha256,
                        f"timing checkpoint differs from its completed interval: {key}")
                require(data["exact_baseline_parity"] is True, f"unqualified parity: {key}")
                require(len(data["samples"]) == SAMPLES, f"wrong measured sample count: {key}")
                config = data["configuration"]
                require(config["outputs"] == interval["mode"], f"output mode differs: {key}")
                if kind == "maespa":
                    require(config["steps"] == interval["size"] and config["copies"] == interval["copies"],
                            f"MAESPA case sizes differ: {key}")
                    require(config["start_slot"] == (13 if interval["size"] == 24 else 1),
                            f"MAESPA forcing slot differs: {key}")
                else:
                    require(config["days"] == interval["size"] and config["samples"] == SAMPLES,
                            f"XPalm days or declared samples differ: {key}")
                returned = interval["result"]
                require(returned["case"] == label.removeprefix(kind + "-"), f"returned case label differs: {key}")
                for phase in PHASES:
                    field = phase + "_s"
                    if phase != "construction" or kind == "maespa" or field in returned:
                        require(returned[field] == [row[phase]["seconds"] for row in data["samples"]],
                                f"returned {phase} vector differs: {key}")
                if kind == "maespa":
                    require(returned["record_count"] == data["record_count"], f"returned record count differs: {key}")
                else:
                    require(all(row["objects"] == returned["objects"] for row in data["samples"]),
                            f"returned object count differs: {key}")
                runtime_fingerprints.add((data["julia"], data["threads"], data["cpu"]))
                image = data["pse_source"] if kind == "maespa" else data["source"]["pse"]
                pse_images[arm].add(digest(image))
                pair[arm] = data
                artifacts[arm] = {"checkpoint": str(path.relative_to(root)), "sha256": checkpoint_sha256}
            before, after = pair["baseline"], pair["candidate"]
            require(before["configuration"] == after["configuration"], f"configuration differs: {label}")
            same_environment = (before["environment"] == after["environment"] if kind == "maespa" else
                                before["source"]["environment"] == after["source"]["environment"])
            require(same_environment, f"environment fingerprints differ: {label}")
            same_science = (before["source"]["aggregate_sha256"] == after["source"]["aggregate_sha256"]
                            if kind == "maespa" else before["source"]["xpalm"] == after["source"]["xpalm"])
            require(same_science, f"scientific sources differ: {label}")
            observer_fields = ("driver_sha256", "observation_schema_sha256", "fixture_sha256")
            if kind == "maespa":
                observer_fields += ("codec_sha256",)
            for field in observer_fields:
                require(before[field] == after[field], f"{field} differs: {label}")
            for field in ("snapshot_sha256", "record_sha256") if kind == "maespa" else ("snapshot_sha256",):
                require(len({row[field] for arm in pair.values() for row in arm["samples"]}) == 1,
                        f"scientific observation differs: {label}/{field}")
            a, b = summary(before["samples"]), summary(after["samples"])
            require(b["execution"]["median_seconds"] > 0 and b["complete"]["median_seconds"] > 0,
                    f"zero comparison denominator: {label}")
            cases.append({"case": label, "kind": kind, "configuration": before["configuration"],
                          "baseline": a, "candidate": b,
                          "execution_speedup": a["execution"]["median_seconds"] / b["execution"]["median_seconds"],
                          "complete_speedup": a["complete"]["median_seconds"] / b["complete"]["median_seconds"],
                          "snapshot_sha256": before["samples"][0]["snapshot_sha256"],
                          "record_count": before.get("record_count"),
                          "objects": before["samples"][0].get("objects"),
                          "executor": {arm: data["samples"][0].get("executor") for arm, data in pair.items()},
                          "artifacts": artifacts})
    require(all(len(images) == 1 for images in pse_images.values()), "PSE source image changed within an arm")
    require(pse_images["baseline"] != pse_images["candidate"], "engine arms have identical PSE images")
    require(len(covered) == 2 * len(cases), "extra quiet-covered cases")
    require(len(runtime_fingerprints) == 1, "Julia version, thread count or CPU differs across cases")
    julia, threads, cpu = next(iter(runtime_fingerprints))
    return {"cases": cases, "pse_image_sha256": {arm: next(iter(images)) for arm, images in pse_images.items()},
            "all_compilation_zero": True, "all_complete_observations_exact": True,
            "all_case_intervals_inside_quiet_windows": True, "samples_per_arm_case": SAMPLES,
            "quiet_window_receipts": len(receipts), "runtime": {"julia": julia, "threads": threads, "cpu": cpu},
            "timing_boundary": "construction, preparation, complete-timeline execution; observers and pretrial GC excluded"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("receipts", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    receipts = [json.loads(path.read_text()) for path in sorted(args.receipts.glob("regular-root-*-quiet-receipt.json"))]
    result = collect(args.root, receipts)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    for row in result["cases"]:
        print(f"{row['case']}: {row['baseline']['execution']['median_seconds'] * 1000:.3f} -> "
              f"{row['candidate']['execution']['median_seconds'] * 1000:.3f} ms; "
              f"execution {row['execution_speedup']:.3f}x; complete {row['complete_speedup']:.3f}x")
