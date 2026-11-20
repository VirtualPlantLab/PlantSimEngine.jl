"""Drain Julia trace output while writing only bounded scalar metadata.

Input is the dedicated --trace-compile stream, never the scientific stderr.
No signature/prefix/argument text is written to disk, including on parse errors.
"""
import argparse
from collections import deque
import heapq
import json
import math
from pathlib import Path
import re
import sys

TIMING = re.compile(rb'^\s*#=\s*([0-9]+(?:\.[0-9]+)?)\s+ms\s*=#\s*precompile\(')
SIMPLE_FUNCTION = re.compile(rb'precompile\(Tuple\{typeof\(([A-Za-z_][A-Za-z_0-9.]*!?)\)[,}]')
LABEL = re.compile(rb'[A-Za-z][A-Za-z_0-9]{0,63}\Z')
SCALARS = {'wall_seconds', 'compile_seconds', 'recompile_seconds', 'allocated_bytes'}
PHASE_BUCKET_LIMIT = 32
TOP_PER_KIND = 12
FUNCTION_LABEL_LIMIT = 120
MARKER_SIDECAR_BYTE_LIMIT = 262144


def drain(source, output, summary_path, *, byte_limit=1048576, tail_limit=128):
    prefix = bytearray()
    line_bytes = 0
    total_bytes = lines = records = written = written_bytes = unrecognized = 0
    tail = deque(maxlen=tail_limit)
    phase_stack = []
    phase_events = boundary_mismatches = 0
    phase_buckets = {}
    overflow_phase_events = overflow_compile_records = 0
    marker_path = Path(summary_path).with_suffix('.phases.json')

    def new_bucket(kind, phase):
        return dict(kind=kind, phase=phase, compile_records=0,
                    named=[], anonymous=[], marker_counts={}, first={}, last={})

    outside = new_bucket('outside_phase', None)
    overflow = new_bucket('phase_bucket_overflow', None)

    def bucket(label):
        if label is None:
            return outside
        if label not in phase_buckets:
            if len(phase_buckets) >= PHASE_BUCKET_LIMIT:
                return overflow
            phase_buckets[label] = new_bucket('phase', label)
        return phase_buckets[label]

    def remember_compile(row):
        nonlocal overflow_compile_records
        target = bucket(row['phase'])
        target['compile_records'] += 1
        if target is overflow:
            overflow_compile_records += 1
        kind = 'named' if row['observed_simple_function'] is not None else 'anonymous'
        heap = target[kind]
        # Sequence makes ties deterministic without comparing dictionaries.
        entry = (row['completed_compile_ms'], row['entry'], row)
        if len(heap) < TOP_PER_KIND:
            heapq.heappush(heap, entry)
        elif entry[:2] > heap[0][:2]:
            heapq.heapreplace(heap, entry)

    def marker_snapshot():
        rows = {}
        counts = []
        for target in (*phase_buckets.values(), overflow):
            if not target['marker_counts']:
                continue
            counts.append(dict(kind=target['kind'], phase=target['phase'],
                               events=target['marker_counts']))
            for row in (*target['first'].values(), *target['last'].values()):
                rows[row['sequence']] = row
        return dict(phase_events=phase_events, phase_boundary_mismatches=boundary_mismatches,
                    phase_bucket_limit=PHASE_BUCKET_LIMIT,
                    overflow_phase_events=overflow_phase_events,
                    retained_markers=[rows[key] for key in sorted(rows)],
                    marker_counts=counts,
                    policy='First and latest valid marker per event kind per admitted phase; repeats counted. '
                           'Excess phase labels share one explicit overflow bucket. '
                           'All markers of a once-per-phase authored protocol with at most32 distinct labels '
                           'are preserved, even after trace quota.')

    def persist_marker(row):
        nonlocal overflow_phase_events
        target = bucket(row['phase'])
        if target is overflow:
            overflow_phase_events += 1
        event = row['event']
        target['marker_counts'][event] = target['marker_counts'].get(event, 0) + 1
        target['first'].setdefault(event, row)
        target['last'][event] = row
        data = (json.dumps(marker_snapshot(), separators=(',', ':')) + '\n').encode()
        # Prefix/label/numeric bounds and <=33 buckets keep this independent
        # sidecar below 256KiB; it is not an unbounded append-only escape hatch.
        if len(data) > MARKER_SIDECAR_BYTE_LIMIT:
            raise RuntimeError('Bounded marker snapshot invariant violated')
        temporary = marker_path.with_suffix(marker_path.suffix + '.tmp')
        temporary.write_bytes(data)
        temporary.replace(marker_path)

    def emit(row):
        nonlocal written, written_bytes
        tail.append(row)
        encoded = (json.dumps(row, separators=(',', ':')) + '\n').encode()
        if written_bytes + len(encoded) <= byte_limit:
            output.write(encoded)
            output.flush()
            written += 1
            written_bytes += len(encoded)

    def finish():
        nonlocal line_bytes, lines, records, unrecognized, phase_events, boundary_mismatches
        lines += 1
        if prefix.startswith(b'COLD_PHASE\t'):
            parts = bytes(prefix).rstrip(b'\r\n').split(b'\t')
            event = parts[1] if len(parts) >= 3 else b''
            valid = line_bytes <= 512 and event in (b'before', b'after', b'failed') and LABEL.fullmatch(parts[2])
            scalars = {}
            if valid:
                for field in parts[3:]:
                    try:
                        key, value = field.decode('ascii').split('=', 1)
                        value = int(value) if key == 'allocated_bytes' else float(value)
                        if key not in SCALARS or key in scalars or value < 0 or not math.isfinite(value):
                            valid = False
                            break
                        scalars[key] = value
                    except (UnicodeError, ValueError, OverflowError):
                        valid = False
                        break
            valid = valid and ((event == b'after' and set(scalars) == SCALARS) or
                               (event != b'after' and not scalars))
            if valid:
                label = parts[2].decode('ascii')
                matched = True
                if event == b'before' and len(phase_stack) < 32:
                    phase_stack.append(label)
                elif event != b'before' and phase_stack and phase_stack[-1] == label:
                    phase_stack.pop()
                else:
                    matched = False
                    boundary_mismatches += 1
                    phase_stack.clear()
                phase_events += 1
                row = {'kind': 'phase', 'event': event.decode('ascii'), 'phase': label,
                       'valid_boundary': matched, 'scalars': scalars, 'sequence': phase_events}
                persist_marker(row)
                emit(row)
            else:
                unrecognized += 1
                # Corrupt control text cannot safely keep a previous phase.
                phase_stack.clear()
            prefix.clear()
            line_bytes = 0
            return
        match = TIMING.match(prefix)
        if match is not None and math.isfinite(float(match[1])):
            method = SIMPLE_FUNCTION.search(prefix)
            row = {'kind': 'compile', 'entry': records + 1, 'completed_compile_ms': float(match[1]),
                   'observed_simple_function': method[1].decode('ascii')[:FUNCTION_LABEL_LIMIT] if method else None,
                   'phase': phase_stack[-1] if phase_stack else None,
                   'source_line_bytes': line_bytes}
            if method and len(method[1]) > FUNCTION_LABEL_LIMIT:
                row['function_label_truncated'] = True
            records += 1
            remember_compile(row)
            emit(row)
        else:
            unrecognized += 1
        prefix.clear()
        line_bytes = 0

    while True:
        block = source.read1(2048)
        if not block:
            break
        total_bytes += len(block)
        start = 0
        while start < len(block):
            end = block.find(b'\n', start)
            stop = len(block) if end < 0 else end + 1
            piece = block[start:stop]
            line_bytes += len(piece)
            if len(prefix) < 512:
                prefix.extend(piece[:512-len(prefix)])
            if end >= 0:
                finish()
            start = stop
    if line_bytes:
        finish()
    tops = [dict(kind=target['kind'], phase=target['phase'], compile_records=target['compile_records'],
                 named=[entry[2] for entry in sorted(target['named'], reverse=True)],
                 anonymous=[entry[2] for entry in sorted(target['anonymous'], reverse=True)])
            for target in (*phase_buckets.values(), outside, overflow)
            if target['compile_records']]
    summary = {'source_bytes_drained': total_bytes, 'source_lines': lines,
               'completed_records': records, 'unrecognized_lines': unrecognized,
               'written_records': written, 'written_bytes': written_bytes,
               'record_byte_limit': byte_limit, 'signature_text_recorded': False,
               'tail_records': list(tail), 'tail_record_limit': tail_limit,
               'phase_events': phase_events, 'phase_boundary_mismatches': boundary_mismatches,
               'open_phase_labels_at_eof': phase_stack,
               'phase_correlation': 'observed stream order only',
               'marker_retention_independent_of_record_quota': True,
               'marker_sidecar': marker_path.name,
               'marker_sidecar_byte_limit': MARKER_SIDECAR_BYTE_LIMIT,
               'marker_snapshot': marker_snapshot(),
               'longest_completed_entries_by_phase': tops,
               'top_entries_per_phase_per_kind': TOP_PER_KIND,
               'phase_bucket_limit': PHASE_BUCKET_LIMIT,
               'overflow_compile_records': overflow_compile_records,
               'maximum_retained_top_entries': (PHASE_BUCKET_LIMIT + 2) * TOP_PER_KIND * 2,
               'record_durations_are_not_additive': True}
    Path(summary_path).write_text(json.dumps(summary, indent=2) + '\n')
    return summary


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--records', required=True, type=Path)
    parser.add_argument('--summary', required=True, type=Path)
    args = parser.parse_args()
    with args.records.open('xb') as destination:
        drain(sys.stdin.buffer, destination, args.summary)
