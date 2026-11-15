"""使用已归档的 iOS 15.5 真实报文检验 H3 比对器，损坏证据必须失败。"""
import copy
import json
from pathlib import Path
import tempfile
import unittest

from compare_h3_production import compare


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


if __name__ == '__main__':
    unittest.main()
