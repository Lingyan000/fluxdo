"""使用已归档的 iOS 15.5 真实报文检验 H3 比对器，损坏证据必须失败。"""
import copy
import json
from pathlib import Path
import tempfile
import unittest

from compare_h3_production import compare, initial_layout, transport_checks


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

    def test_transport_checks_reject_corrupt_initial_tls_and_parameters(self):
        self.assertTrue(all(transport_checks(self.fixture['profile'], self.fixture['capture'])[0].values()))
        for mutate in [lambda d: d['capture']['initial'].update(datagram_sizes=[1]),
                       lambda d: d['capture'].update(tls={}),
                       lambda d: d['capture'].update(transport_parameters=[])]:
            data = copy.deepcopy(self.fixture)
            mutate(data)
            self.assertFalse(all(transport_checks(data['profile'], data['capture'])[0].values()))

    def test_transport_checks_require_frozen_boundary_and_calibration(self):
        for mutate in [lambda d: d['capture']['h3'][0]['first_request_boundary'].update(status='timed_out'),
                       lambda d: d['profile'].update(wire_fields=[]),
                       lambda d: d['capture'].update(h3=[])]:
            data = copy.deepcopy(self.fixture)
            mutate(data)
            self.assertFalse(all(transport_checks(data['profile'], data['capture'])[0].values()))

    def test_archived_native_sample_passes(self):
        self.assertTrue(self.evaluate())

    def test_additional_sampled_phase_is_required_and_checked(self):
        def extend(data):
            data['profile']['wire_fields'].append(copy.deepcopy(data['profile']['wire_fields'][-1]))
            request=copy.deepcopy(data['capture']['h3'][-1])
            request['request']['stream_id']=12
            data['capture']['h3'].append(request)
        self.assertTrue(self.evaluate(extend))
        def missing(data):
            extend(data)
            data['capture']['h3'].pop()
        self.assertFalse(self.evaluate(missing))
        def corrupt(data):
            extend(data)
            data['capture']['h3'][-1]['request']['fields_complete']=False
        self.assertFalse(self.evaluate(corrupt))

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

    def with_request_priorities(self, data):
        for phase in range(len(data['profile']['wire_fields'])):
            frame={'frame_type':0xf0700, 'element_id':phase*4, 'value':list(b'u=1, i'), 'length':7}
            data['profile']['warm_boundary']['control'].append(copy.deepcopy(frame))
            if phase == 0:
                data['profile']['boundary']['control'].append(copy.deepcopy(frame))
            for request in data['capture']['h3'][phase:]:
                request['connection']['control'].append(copy.deepcopy(frame))

    def test_priority_after_frozen_headers_but_before_response_passes(self):
        self.assertTrue(self.evaluate(self.with_request_priorities))

    def test_missing_early_priority_is_not_rescued_by_later_snapshot(self):
        def corrupt(data):
            self.with_request_priorities(data)
            data['capture']['h3'][0]['connection']['control'].pop()
        self.assertFalse(self.evaluate(corrupt))

    def test_wrong_or_duplicate_request_priority_fails(self):
        for mode in ('value', 'stream', 'duplicate'):
            def corrupt(data):
                self.with_request_priorities(data)
                frames=data['capture']['h3'][1]['connection']['control']
                if mode == 'value': frames[-1]['value']=list(b'u=7')
                elif mode == 'stream': frames[-1]['element_id']=12
                else: frames.append(copy.deepcopy(frames[-1]))
            with self.subTest(mode=mode):
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

    def test_archived_windows_unsplit_crypto_with_ping_is_not_ordered(self):
        data=json.loads((Path(__file__).parent/'testdata/windows131_initial_ping.json').read_text())
        self.assertIsNone(initial_layout(data['native'])['ordered_crypto_chunk_size'])
        actual=initial_layout(data['core'])
        self.assertTrue(actual['complete_nonoverlapping_crypto'])
        self.assertEqual(actual['crypto_fragment_lengths'],[1191,597])
        self.assertEqual(actual['pings_per_packet'],[0,2])
        self.assertIsNone(actual['ordered_crypto_chunk_size'])

    def test_reversed_single_crypto_packets_are_not_ordered(self):
        flight={'frames':[[{'Crypto':{'offset':100,'len':100}}],
                          [{'Crypto':{'offset':0,'len':100}}]]}
        result=initial_layout(flight)
        self.assertTrue(result['complete_nonoverlapping_crypto'])
        self.assertIsNone(result['ordered_crypto_chunk_size'])


if __name__ == '__main__':
    unittest.main()
