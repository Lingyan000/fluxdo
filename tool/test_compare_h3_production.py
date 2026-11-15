"""使用已归档的 iOS 15.5 真实报文检验 H3 比对器，损坏证据必须失败。"""
import copy
import json
from pathlib import Path
import tempfile
import unittest

from compare_h3_production import compare, initial_layout


class H3EvidenceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = json.loads((Path(__file__).parent / 'testdata/ios15_h3_replay.json').read_text())

    def evaluate(self, mutate=None):
        data = copy.deepcopy(self.fixture)
        if mutate:
            mutate(data)
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'client').mkdir()
            (root / 'server').mkdir()
            (root / 'client/profile.json').write_text(json.dumps(data['profile']))
            (root / 'server/h3-capture.json').write_text(json.dumps(data['capture']))
            return compare(root)['all_checked_fields_match']

    def test_archived_native_sample_passes(self):
        self.assertTrue(self.evaluate())

    def test_incomplete_fields_fail(self):
        for phase in range(3):
            with self.subTest(phase=phase):
                self.assertFalse(self.evaluate(lambda d: d['capture']['h3'][phase]['request'].update(fields_complete=False)))

    def test_empty_or_misaligned_names_fail(self):
        for values in ({'names': [], 'fields': []}, {'names': []}, {'names': None}):
            with self.subTest(values=values):
                self.assertFalse(self.evaluate(lambda d: d['capture']['h3'][0]['request'].update(values)))

    def test_unfrozen_boundary_fails(self):
        self.assertFalse(self.evaluate(lambda d: d['capture']['h3'][0]['first_request_boundary'].update(status='timed_out')))

    def test_partial_boundary_fails(self):
        self.assertFalse(self.evaluate(lambda d: d['capture']['h3'][1]['connection']['completeness'].update(qpack=False)))
        self.assertFalse(self.evaluate(lambda d: d['profile']['boundary']['completeness'].pop('streams')))

    def test_missing_request_or_duplicate_stream_fails(self):
        self.assertFalse(self.evaluate(lambda d: d['capture'].update(h3=[])))
        self.assertFalse(self.evaluate(lambda d: d['capture']['h3'].pop()))
        self.assertFalse(self.evaluate(lambda d: d['capture']['h3'][1]['request'].update(stream_id=0)))

    def test_failed_driver_fails(self):
        self.assertFalse(self.evaluate(lambda d: d['capture'].update(driver_success=False)))

    def test_incomplete_initial_or_qpack_binding_fails(self):
        self.assertFalse(self.evaluate(lambda d: d['capture']['initial'].update(complete=False)))
        self.assertFalse(self.evaluate(lambda d: d['profile']['boundary']['encoder_bindings'].update(complete=False)))

    def test_mixed_connections_fail(self):
        self.assertFalse(self.evaluate(lambda d: d['capture']['h3'][1].update(flow_id=999)))

    def test_warm_control_semantics_fail(self):
        def corrupt(data):
            frames=data['capture']['h3'][-1]['connection']['control']
            next(frame for frame in frames if frame['frame_type']==13)['element_id']+=1
        self.assertFalse(self.evaluate(corrupt))

    def test_missing_or_duplicate_crypto_ranges_fail(self):
        self.assertFalse(self.evaluate(lambda d: d['capture']['initial'].update(frames=[])))
        def duplicate(data):
            frames=data['capture']['initial']['frames'][0]
            frames.append(next(copy.deepcopy(f) for f in frames if isinstance(f,dict) and 'Crypto' in f))
        self.assertFalse(self.evaluate(duplicate))

    def test_cross_packet_interleave_is_not_intra_packet_shuffle(self):
        def crypto(offset, length):
            return {'Crypto': {'offset':offset, 'len':length}}
        source={'frames':[[crypto(900,100),crypto(0,60)],[crypto(60,840)]]}
        old_core={'frames':[[crypto(0,700)],[crypto(900,100),crypto(700,200)]]}
        self.assertTrue(initial_layout(source)['cross_packet'])
        self.assertFalse(initial_layout(old_core)['cross_packet'])
        self.assertTrue(initial_layout(source)['complete_nonoverlapping_crypto'])
        self.assertTrue(initial_layout(old_core)['complete_nonoverlapping_crypto'])

    def test_archived_ios26_packet_sizes_hide_crypto_chunk_mismatch(self):
        data=json.loads((Path(__file__).parent/'testdata/ios26_initial_layout.json').read_text())
        self.assertEqual(data['native']['datagram_sizes'],data['previous_core']['datagram_sizes'])
        self.assertEqual(initial_layout(data['native'])['ordered_crypto_chunk_size'],999)
        self.assertEqual(initial_layout(data['previous_core'])['ordered_crypto_chunk_size'],1161)


if __name__ == '__main__':
    unittest.main()
