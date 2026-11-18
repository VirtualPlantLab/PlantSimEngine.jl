"""Bound failed JuliaC diagnostics to owned compiler descendants only.

The hosted qualification launches this monitor with its own getpid(),
unique attempt log and finished marker. It never sends a signal without BOTH current ancestry to that exact
runner and a verified open descriptor for that exact private compile.log.
"""
from pathlib import Path
import argparse
import json
import os
import re
import signal
import subprocess
import time

HEADER = re.compile(rb'(?:Verifier error|Error) #(\d+):')
PSE_SOURCE_FRAME = re.compile(
    rb'(?m)^[ \t]*@[^\r\n]*/frozen-pse/(src/[^\r\n]+\.jl:\d+[^\r\n]*)\r?\n')
FIRST_HEADER_FRAME_GRACE = 2.0

def processes():
    raw = subprocess.run(['ps', '-axo', 'pid=,ppid=,command='], check=True,
        capture_output=True, text=True).stdout
    result = {}
    for line in raw.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) == 3:
            result[int(fields[0])] = (int(fields[1]), fields[2])
    return result

def descendant(pid, parent, table):
    seen = set()
    while pid in table and pid not in seen:
        seen.add(pid)
        pid = table[pid][0]
        if pid == parent:
            return True
    return False

def owns_log(pid, log):
    result = subprocess.run(['lsof', '-a', '-p', str(pid), '-Fn', str(log)],
        capture_output=True, text=True)
    return result.returncode == 0 and ('n' + str(log)) in result.stdout.splitlines()

def process_start(pid):
    result = subprocess.run(['ps', '-p', str(pid), '-o', 'lstart='],
        capture_output=True, text=True)
    if result.stderr.strip():
        raise RuntimeError('Cannot establish owned compiler exit status')
    return result.stdout.strip() or None

def terminate_owned_compiler(parent, log, stopped, starts):
    table = processes()
    candidates = [pid for pid, (_, command) in table.items()
        if 'juliac-buildscript.jl' in command and descendant(pid, parent, table)]
    for pid in candidates:
        if not owns_log(pid, log):
            continue
        # Recheck ancestry and command immediately before signalling; never
        # persist unrelated process arguments or infer ownership by PID alone.
        live = processes()
        if (pid not in live or 'juliac-buildscript.jl' not in live[pid][1]
                or not descendant(pid, parent, live) or not owns_log(pid, log)):
            continue
        started = process_start(pid)
        if started is None:
            continue
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            # A normal exit between the ownership check and SIGTERM is not a
            # monitor failure and must not prevent the receipt being written.
            continue
        stopped.append(pid)
        starts[pid] = started
    deadline = time.monotonic() + 10
    remaining = list(stopped)
    while remaining and time.monotonic() < deadline:
        # Closing a descriptor is NOT process exit. Once signalled, use the
        # observed process identity, even if it has closed the diagnostic log.
        remaining = [pid for pid in remaining if process_start(pid) == starts[pid]]
        if remaining:
            time.sleep(0.1)
    return remaining

def header_count(log):
    # Compiler teardown may emit another header after SIGTERM. Count the full
    # preserved log at receipt time, not merely the threshold that stopped it.
    count, carry = 0, b''
    with log.open('rb') as stream:
        while chunk := stream.read(1_048_576):
            data = carry + chunk
            safe_end = max(0, len(data) - 64)
            count += sum(match.start() < safe_end for match in HEADER.finditer(data))
            carry = data[safe_end:]
    return count + len(HEADER.findall(carry))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--parent', type=int, required=True)
    parser.add_argument('--log', type=Path, required=True)
    parser.add_argument('--finished', type=Path, required=True)
    parser.add_argument('--receipt', type=Path, required=True)
    parser.add_argument('--errors', type=int, default=1)
    parser.add_argument('--seconds', type=float, default=900)
    args = parser.parse_args()
    log, receipt = args.log.resolve(), args.receipt.resolve()
    assert args.parent > 1 and args.parent != os.getpid()
    assert log.name == 'compile.log' and receipt.parent == log.parent
    assert args.finished.resolve().parent == log.parent
    assert not receipt.exists() and args.errors > 0 and args.seconds > 0
    started, offset, carry, headers = time.monotonic(), 0, b'', set()
    reason, stopped, remaining, monitor_error = 'parent_finished', [], [], None
    starts = {}
    compiler_observations = {}
    first_header_seconds = None
    first_source_frame = None
    try:
        while not args.finished.exists():
            observed_processes = processes()
            for pid,(ppid,command) in observed_processes.items():
                if (('juliac-buildscript.jl' in command or ('--project=' in command and 'Pkg.precompile' in command)) and
                        descendant(pid,args.parent,observed_processes) and
                        owns_log(pid,log) and pid not in compiler_observations):
                    compiler_observations[pid] = dict(pid=pid,ppid=ppid,argv=command,
                        process_start=process_start(pid),observed_seconds=time.monotonic()-started)
                    import shlex, shutil
                    words = shlex.split(command)
                    project_arg = next((w.split('=', 1)[1] for w in words if w.startswith('--project=')), None)
                    if project_arg:
                        directory = Path(project_arg)
                        if directory.is_file():
                            directory = directory.parent
                        for filename in ('Project.toml', 'Manifest.toml'):
                            source = directory / filename
                            if source.is_file():
                                target = receipt.parent / ('actual-compiler-' + str(pid) + '-' + filename)
                                shutil.copy2(source, target)
                                compiler_observations[pid][filename] = str(target)

            if log.exists():
                with log.open('rb') as stream:
                    stream.seek(offset)
                    chunk = stream.read(1_048_576)
                if chunk:
                    data = carry + chunk
                    base = offset - len(carry)
                    headers.update(base + match.start() for match in HEADER.finditer(data))
                    if headers and first_header_seconds is None:
                        first_header_seconds = time.monotonic() - started
                    if headers and first_source_frame is None:
                        ordered = sorted(headers)
                        first, following = ordered[0], ordered[1] if len(ordered) > 1 else None
                        for match in PSE_SOURCE_FRAME.finditer(data):
                            position = base + match.start()
                            if position > first and (following is None or position < following):
                                first_source_frame = {
                                    'source': match[1].decode(errors='replace'),
                                    'byte_offset': position}
                                break
                    offset += len(chunk)
                    carry = data[-1024:]
            elapsed = time.monotonic() - started
            error_limit = len(headers) >= args.errors
            frame_ready = (first_source_frame is not None or
                (first_header_seconds is not None and elapsed - first_header_seconds >= FIRST_HEADER_FRAME_GRACE))
            log_limit = log.exists() and log.stat().st_size > 32 * 1024 * 1024
            if (error_limit and frame_ready) or elapsed >= args.seconds or log_limit:
                reason = 'partial_verifier_error_limit' if error_limit else ('diagnostic_log_budget' if log_limit else 'time_budget')
                remaining = terminate_owned_compiler(args.parent, log, stopped, starts)
                # If ownership cannot be established, do not kill an unknown
                # process. The hosted job retains this receipt for explicit cancellation.
                if stopped:
                    if remaining:
                        reason += '_shutdown_unverified'
                    break
                reason += '_owned_compiler_not_found'
                break
            if args.parent not in observed_processes:
                reason = 'parent_exited_without_finished_marker'
                break
            time.sleep(0.2)
    except Exception as error:
        reason = 'monitor_failed'
        monitor_error = type(error).__name__
        remaining = list(stopped)
    try:
        final_headers = header_count(log) if log.exists() else 0
    except Exception as error:
        reason = 'monitor_failed'
        monitor_error = type(error).__name__
        final_headers = len(headers)
    result = {'purpose': 'first_error_triage_same_full_replay', 'reason': reason,
        'stop_threshold': args.errors,
        'first_observed_header_seconds': first_header_seconds,
        'first_header_pse_frame': first_source_frame,
        'first_header_frame_grace_seconds': FIRST_HEADER_FRAME_GRACE,
        'actual_header_count': final_headers,
        'header_match': '(?:Verifier error|Error) #',
        'observed_partial_error_headers': final_headers,
        'threshold_observed_headers': len(headers), 'log_bytes_read': offset,
        'seconds': time.monotonic() - started, 'signalled_owned_compilers': stopped,
        'signalled_process_start_ids': starts,
        'remaining_owned_compilers': remaining,
        'requires_owned_kaimon_cancel': bool(remaining) or reason.endswith('not_found'),
        'requires_owned_child_inventory': bool(remaining) or reason.endswith('not_found') or
            reason in ('parent_exited_without_finished_marker', 'monitor_failed'),
        'actual_compiler_observations': list(compiler_observations.values()),
        'monitor_error_type': monitor_error,
        'can_establish_native_pass': False}
    temporary = receipt.with_suffix('.partial')
    temporary.write_text(json.dumps(result, indent=2) + '\n')
    temporary.replace(receipt)

def verify_receipt(receipt, destination):
    import shlex
    data = json.loads(Path(receipt).read_text())
    rows = []
    for item in data.get('actual_compiler_observations', []):
        words = shlex.split(item['argv'])
        safe_compiler = 'juliac-buildscript.jl' in item['argv']
        manifest = item.get('Manifest.toml')
        project = item.get('Project.toml')
        if not manifest or not project:
            continue
        flags = ' ' + ' '.join(words) + ' '
        rows.append(dict(pid=item['pid'], is_safe_compiler=safe_compiler,
            safe='--trim=safe' in words or ' --trim safe ' in flags,
            generic=any(w in words for w in ('--cpu-target=generic', '-Cgeneric')) or
                ' -C generic ' in flags or ' --cpu-target generic ' in flags,
            no_L=not any(w == '-L' or w.startswith('-L') or w.startswith('--load') for w in words),
            manifest=manifest, project=project))
    def quote(value):
        return json.dumps(value)
    with Path(destination).open('w') as out:
        for row in rows:
            out.write('[[observations]]\n')
            for key,value in row.items():
                scalar = str(value).lower() if isinstance(value,bool) else str(value) if isinstance(value,int) else quote(value)
                out.write(key + ' = ' + scalar + '\n')

if __name__ == '__main__':
    import sys
    if '--verify-receipt' in sys.argv:
        parser=argparse.ArgumentParser()
        parser.add_argument('--verify-receipt', required=True)
        parser.add_argument('--verification', required=True)
        args=parser.parse_args()
        verify_receipt(args.verify_receipt,args.verification)
    else:
        main()
