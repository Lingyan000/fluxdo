"""运行中的 NetLog 不一定封闭，不能把截断静默视为完整证据。"""
import json
import unittest

from summarize_h3_netlog import read_netlog, summarize


class NetlogTest(unittest.TestCase):
    def test_complete_document(self):
        data = {'constants': {}, 'events': [{'type': 1}]}
        parsed, state = read_netlog(json.dumps(data))
        self.assertEqual(parsed, data)
        self.assertTrue(state['document_complete'])

    def test_live_prefix_keeps_only_complete_events(self):
        prefix = '{"constants":{},"events":[{"type":1,"params":{"text":"] , 中文"}},\n'
        for suffix in ['', '{"type":2,"params":']:
            with self.subTest(suffix=suffix):
                parsed, state = read_netlog(prefix + suffix)
                self.assertEqual(len(parsed['events']), 1)
                self.assertEqual(parsed['events'][0]['type'], 1)
                self.assertFalse(state['document_complete'])
                self.assertEqual(state['discarded_tail_bytes'], len(suffix.encode('utf-8')))

    def test_broken_constants_rejected(self):
        with self.assertRaises(json.JSONDecodeError):
            read_netlog('{"constants":{"bad":,"events":[')

    def test_background_quic_is_excluded(self):
        data = {'constants': {'logEventTypes': {'QUIC_SESSION': 1}}, 'events': [
            {'type': 1, 'source': {'id': 1}, 'params': {'host': 'background.test', 'port': 443}},
            {'type': 1, 'source': {'id': 2}, 'params': {'host': 'localhost', 'port': 1234}},
            {'type': 1, 'source': {'id': 3}, 'params': {'host': 'localhost', 'port': 9999}},
        ]}
        self.assertEqual(summarize(data, {1234})['local_quic_sessions'], 1)


if __name__ == '__main__':
    unittest.main()
