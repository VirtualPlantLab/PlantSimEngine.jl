"""Four warm processes, one active computation and eight balanced blocks per mode."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
from statistics import median
import subprocess
import sys
import time

recipe = Path(__file__).resolve().parent
common = recipe.parent / "xpalm-matched"
spec = importlib.util.spec_from_file_location("xpalm_matched", common / "run.py")
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)
assert bench.scenario == "legacy"
roles = dict(main=bench.revisions["main"], fast=bench.revisions["historical"],
             before="fc7fdec5e3b1287bcb0d520540381988ed7f915f", candidate=bench.revisions["candidate"])
assert roles["candidate"] == "3d5a1b68627d95d3860cbd248b17c00ed6398bee"
assert bench.mtg_revision == "b3b39f5d33543fe2775756782ec1c4de33ba5775"
reference_path = common / "reference.json"
reference_sha = bench.digest(reference_path)
reference = json.loads(reference_path.read_text())
results = bench.results

# Use the same scientific trajectory and timing harness as the three-arm run.
# The extra allocation pass runs after all timed blocks. Nothing samples allocation
# counters inside the ordinary per-day timer of the performance passes.
standard = common / "compare.jl"
assert bench.digest(standard) == "cc7b9a4db48dba2b8951b0d49c0a2885929770eb349a0e44b5b610e7daea4a73"
source, marker, _ = standard.read_text().partition('@testset "4,160 days, ordinary PSE on the frozen XPalm controls" begin')
assert marker
old_sig = "function trajectory(mode, reference)"
old_step = "        stepped!(sim, elapsed, counts)"
assert source.count(old_sig) == source.count(old_step) == 1
source = source.replace(old_sig,"function trajectory(mode, reference, bytes=nothing)")
source = source.replace(old_step, """        if isnothing(bytes)
            stepped!(sim, elapsed, counts)
        else
            allocation_steps!(sim, elapsed, counts, bytes)
        end""")
worker = common / "current-interleaved-driver.jl"
worker.write_text(source + (recipe / "worker.jl").read_text())

def read_json(path):
    return json.loads(path.read_text())

def save(name, value):
    path = results / (name + ".json")
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(value, indent=2) + "\n")
    tmp.replace(path)

def status(process):
    d = {}
    for line in Path(f"/proc/{process.pid}/status").read_text().splitlines():
        if line.startswith(("VmRSS:", "VmHWM:", "VmSwap:", "Cpus_allowed_list:")):
            key,val=line.split(":",1)
            d[key] = val.strip()
    return d

def host_status():
    mem = dict(line.split(":",1) for line in Path("/proc/meminfo").read_text().splitlines())
    return {k:mem[k].strip() for k in ("MemTotal","MemAvailable","SwapTotal","SwapFree")}

def source_check(arm, env, role):
    pinned = bench.provenance[role]
    assert all(bench.digest(env / n) == h for n,h in pinned["files"].items())
    assert not bench.git_text(arm / "PlantSimEngine", "status", "--porcelain", "--untracked-files=no")
    assert not bench.git_text(arm / "MultiScaleTreeGraph", "status", "--porcelain", "--untracked-files=no")
    assert not bench.git_text(arm / "XPalm", "diff", "--name-only")
    assert bench.git_text(arm / "XPalm", "write-tree") == pinned["xpalm_tree"]

prepared = {r:bench.prepare_role(r,rev) for r,rev in roles.items()}
assert len({s["xpalm_tree"] for s in bench.provenance.values()}) == 1
os.environ["HOSTNAME"] = os.uname().nodename
processes, schedule = {}, []
cpuinfo = next(line.split(":",1)[1].strip() for line in Path("/proc/cpuinfo").read_text().splitlines() if line.startswith("model name"))
host = dict(model=cpuinfo,kernel=os.uname().release,hostname=os.uname().nodename,initial_memory=host_status(),
            job=os.environ["GITHUB_RUN_ID"],workflow_commit=os.environ["GITHUB_SHA"],reference_sha256=reference_sha,
            trajectory_sha256=bench.digest(standard),worker_sha256=bench.digest(worker),revisions=roles,
            mtg=bench.mtg_revision,xpalm=bench.xpalm_revision)
save("host",host)
science = None
cpu = None
def request(role,phase,mode,index):
    global science, cpu
    seq = len(schedule) + 1
    p = processes[role]
    print(f"{seq} {phase} {mode} {index} {role}",flush=True)
    p.stdin.write(f"{seq} {phase} {mode} {index}\n"); p.stdin.flush()
    path = results / (role + ".json")
    while True:
        if p.poll() is not None:
            raise RuntimeError(f"{role} stopped at {phase}/{mode}/{index} with {p.returncode}")
        if path.exists():
            try:
                report=read_json(path)
            except FileNotFoundError:
                continue
            row=report["rows"][-1]
            if row["seq"]==seq:
                break
        time.sleep(0.5)
    assert row["phase"]==phase and row["mode"]==mode and row["index"]==index and report["pid"]==p.pid
    assert report["hostname"]==os.environ["HOSTNAME"] and report["julia"]=="1.13.3"
    if science is None:
        science=row["science"];cpu=report["cpu"]
        host["julia_commit"]=report["julia_commit"];host["cpu"]=cpu
        host["previous_linux"]=bench.previous_linux_check(science,cpu,report["julia_commit"])
        assert all(science["components"][k]==reference["components"][k] for k in ("rngs","topology","source_topology","step"))
        save("host",host)
    assert report["cpu"]==cpu and report["julia_commit"]==host["julia_commit"] and row["science"]==science
    # No filtering of timings. Failing a scientific or host condition fails this run.
    if phase=="measure":
        assert all(t["compile_seconds"]==t["recompile_seconds"]==0 for t in row["times"].values())
        assert all(row["before"][k]==row["after"][k] for k in ("swap_in","swap_out"))
    schedule.append(dict(seq=seq,arm=role,phase=phase,mode=mode,index=index,
                         host=host_status(),worker=status(p)))
    save("schedule",schedule)

# Williams square: each role runs at every position twice in the eight blocks,
# with each ordered pair of distinct roles occurring equally often per mode.
order = [['main','fast','candidate','before'],['fast','before','main','candidate'],
         ['before','candidate','fast','main'],['candidate','main','before','fast']]
assert all(sorted(row)==sorted(roles) for row in order)
try:
    for role,(_,env) in prepared.items():
        process=subprocess.Popen(bench.command(env,str(worker),str(results),role,str(reference_path)),stdin=subprocess.PIPE,text=True)
        processes[role]=process
        request(role,"warm","full",0);request(role,"warm","daily",0)
    for block in range(8):
        modes=("full","daily") if block%2==0 else ("daily","full")
        for mode in modes:
            sequence=order[(block+(2 if mode=="daily" else 0))%4]
            for role in sequence:
                request(role,"measure",mode,block+1)
    for role in order[0]:
        request(role,"allocation","daily",0)
    for process in processes.values():
        process.stdin.write("exit\n");process.stdin.close()
    assert all(process.wait()==0 for process in processes.values())
finally:
    for process in processes.values():
        if process.poll() is None:
            process.terminate()
for role,(arm,env) in prepared.items():
    source_check(arm,env,role)
assert bench.digest(reference_path)==reference_sha and len(schedule)==76
for role in roles:
    replays=read_json(results/(role+".json"))["rows"]
    assert len(replays)==19 and all(r["science"]==science for r in replays)
    assert read_json(results/(role+"-reference.json"))["object_counts"]==reference["object_counts"]
    assert len(read_json(results/(role+"-allocation.json"))["step_bytes"])==4160

arms = {}
for role in roles:
    rows=read_json(results/(role+".json"))["rows"]
    raw={}
    for mode in ("full","daily"):
        sample=sorted((r for r in rows if r["mode"]==mode and r["phase"]=="measure"),key=lambda r:r["index"])
        assert [r["index"] for r in sample]==list(range(1,9))
        raw[mode]=sample
    arm={k:[r["times"][phase][field] for r in raw["full"]] for k,phase,field in
         (("full_s","execution","seconds"),("execution_bytes","execution","bytes"),("gc_s","execution","gctime"),("prepare_s","preparation","seconds"),("construct_s","construction","seconds"))}
    arm.update({k:[r[k] for r in raw["daily"]] for k in ("growth_seconds","ordinary_seconds")})
    arms[role]=arm
stable_modes=["full_s","growth_seconds","ordinary_seconds","prepare_s","execution_bytes"]
ratios={base:{k:[c/b for c,b in zip(arms["candidate"][k],arms[base][k],strict=True)] for k in stable_modes} for base in ("fast","before","main")}
save("comparison",dict(science=science,arms=arms,paired_ratios=ratios,reference_sha256=reference_sha,
                       all_4161_counts_match=True,nominal_memory=host["initial_memory"],repetitions_per_mode=8))
for arm,values in arms.items():print(arm,{k:median(v) for k,v in values.items()},flush=True)
