"""Drain Julia trace output while writing only bounded scalar metadata.

Input is the dedicated --trace-compile stream, never the scientific stderr.
No signature/prefix/argument text is written to disk, including on parse errors.
"""
import argparse
from collections import deque
import json
import math
from pathlib import Path
import re
import sys

TIMING = re.compile(rb'^\s*#=\s*([0-9]+(?:\.[0-9]+)?)\s+ms\s*=#\s*precompile\(')
SIMPLE_FUNCTION = re.compile(rb'precompile\(Tuple\{typeof\(([A-Za-z_][A-Za-z_0-9.]*!?)\)[,}]')
LABEL = re.compile(rb'[A-Za-z][A-Za-z_0-9]{0,63}\Z')
SCALARS = {'wall_seconds', 'compile_seconds', 'recompile_seconds', 'allocated_bytes'}


def drain(source, output, summary_path, *, byte_limit=1048576, tail_limit=128):
    prefix = bytearray()
    line_bytes = 0
    total_bytes = lines = records = written = written_bytes = unrecognized = 0
    tail = deque(maxlen=tail_limit)
    phase_stack = []
    phase_events = boundary_mismatches = 0

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
            valid = event in (b'before', b'after', b'failed') and LABEL.fullmatch(parts[2])
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
                emit({'kind': 'phase', 'event': event.decode('ascii'), 'phase': label,
                      'valid_boundary': matched, 'scalars': scalars})
            else:
                unrecognized += 1
            prefix.clear()
            line_bytes = 0
            return
        match = TIMING.match(prefix)
        if match is not None and math.isfinite(float(match[1])):
            method = SIMPLE_FUNCTION.search(prefix)
            row = {'kind': 'compile', 'entry': records + 1, 'completed_compile_ms': float(match[1]),
                   'observed_simple_function': method[1].decode('ascii') if method else None,
                   'phase': phase_stack[-1] if phase_stack else None,
                   'source_line_bytes': line_bytes}
            records += 1
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
    summary = {'source_bytes_drained': total_bytes, 'source_lines': lines,
               'completed_records': records, 'unrecognized_lines': unrecognized,
               'written_records': written, 'written_bytes': written_bytes,
               'record_byte_limit': byte_limit, 'signature_text_recorded': False,
               'tail_records': list(tail), 'tail_record_limit': tail_limit,
               'phase_events': phase_events, 'phase_boundary_mismatches': boundary_mismatches,
               'open_phase_labels_at_eof': phase_stack,
               'phase_correlation': 'observed stream order only',
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
