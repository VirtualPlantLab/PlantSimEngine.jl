import io
import json
from pathlib import Path
import tempfile
import unittest

from cold_trace_filter import drain


class TraceFilterChecks(unittest.TestCase):
    def run_filter(self, data, **options):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'summary.json'
            output = io.BytesIO()
            summary = drain(io.BytesIO(data), output, path, **options)
            combined = output.getvalue() + path.read_bytes()
            self.assertNotIn(b'Tuple{', combined)
            self.assertNotIn(b'SECRET_SIGNATURE', combined)
            return output.getvalue(), summary

    def test_giant_signature_is_drained_and_never_recorded(self):
        line = b'#= 123.5 ms =# precompile(Tuple{typeof(PlantSimEngine.step!), SECRET_SIGNATURE' + b'X'*20000000 + b'})\n'
        output, summary = self.run_filter(line)
        self.assertEqual(summary['source_bytes_drained'],len(line))
        self.assertEqual(summary['completed_records'],1)
        self.assertEqual(json.loads(output)['observed_simple_function'],'PlantSimEngine.step!')

    def test_simple_function_and_eof(self):
        output, summary = self.run_filter(b'#= 2.0 ms =# precompile(Tuple{typeof(Base.identity), Int64})')
        self.assertEqual(json.loads(output)['observed_simple_function'],'Base.identity')
        self.assertEqual(summary['completed_records'],1)

    def test_quota_keeps_draining_and_tail_is_bounded(self):
        data=b'#= 3 ms =# precompile(Tuple{typeof(Base.identity), Int64})\n'*10000
        output, summary = self.run_filter(data,byte_limit=300,tail_limit=3)
        self.assertLessEqual(len(output),300)
        self.assertEqual(summary['completed_records'],10000)
        self.assertEqual(summary['source_bytes_drained'],len(data))
        self.assertEqual(len(summary['tail_records']),3)

    def test_unknown_format_has_no_raw_fallback(self):
        output, summary = self.run_filter(b'SECRET_SIGNATURE Tuple{Any}\n#= NaN ms =# precompile(Tuple{Any})\n')
        self.assertEqual(output,b'')
        self.assertEqual(summary['unrecognized_lines'],2)

    def test_phases_attach_only_explicit_safe_labels(self):
        trace = b'#= 3 ms =# precompile(Tuple{typeof(Base.identity), Int64})\n'
        data = (b'COLD_PHASE\tbefore\tconstruction\n' + trace +
                b'COLD_PHASE\tafter\tconstruction\twall_seconds=2.0\tcompile_seconds=1.0\trecompile_seconds=0.5\tallocated_bytes=80\n' + trace)
        output, summary = self.run_filter(data)
        rows = [json.loads(line) for line in output.splitlines()]
        self.assertEqual([r['phase'] for r in rows if r['kind']=='compile'],['construction',None])
        self.assertEqual(summary['phase_events'],2)
        self.assertEqual(summary['phase_boundary_mismatches'],0)

    def test_bad_phase_payload_and_mismatch_are_not_attributed(self):
        data = (b'COLD_PHASE\tbefore\tconstruction\nCOLD_PHASE\tfailed\tother\n' +
                b'COLD_PHASE\tbefore\tSECRET_SIGNATURE Tuple{Any}\n' +
                b'#= 3 ms =# precompile(Tuple{typeof(Base.identity), Int64})\n')
        output, summary = self.run_filter(data)
        rows = [json.loads(line) for line in output.splitlines()]
        self.assertIsNone(rows[-1]['phase'])
        self.assertEqual(summary['phase_boundary_mismatches'],1)
        self.assertEqual(summary['unrecognized_lines'],1)


if __name__ == '__main__':
    unittest.main()
