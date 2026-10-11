import contextlib
import io
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import register_apple_share as share


class ShareIdentifierTests(unittest.TestCase):
    def exercise(self, existing, enabled):
        calls = []
        def api(path, method='GET', body=None, query=None):
            calls.append((path, method, body, query))
            record = {'id': 'private-id-fixture', 'attributes': {'identifier': share.SHARE, 'name': 'private owner fixture'}}
            if path == 'bundleIds':
                if method == 'POST': return {'data': record}
                self.assertEqual(query, {'filter[identifier]': share.SHARE})
                return {'data': [record] if existing else []}
            if path.endswith('/bundleIdCapabilities'):
                return {'data': [{'attributes': {'capabilityType': 'APP_GROUPS'}}] if enabled else []}
            if path == 'bundleIdCapabilities': return {'data': {}}
            self.fail('Unexpected project or certificate query')
        output = io.StringIO()
        with patch.object(share, 'api', side_effect=api), contextlib.redirect_stdout(output): share.prepare()
        self.assertNotIn('private-id-fixture', output.getvalue())
        self.assertNotIn('private owner fixture', output.getvalue())
        return calls

    def test_reuses_the_same_id_and_capability_without_mutations(self):
        self.assertTrue(all(method == 'GET' for _, method, _, _ in self.exercise(True, True)))

    def test_creates_only_the_fixed_id_and_required_capability(self):
        calls = self.exercise(False, False)
        creates = [(path, body) for path, method, body, _ in calls if method == 'POST']
        self.assertEqual([path for path, _ in creates], ['bundleIds', 'bundleIdCapabilities'])
        self.assertEqual(creates[0][1]['data']['attributes']['identifier'], share.SHARE)
        self.assertEqual(creates[1][1]['data']['attributes']['capabilityType'], 'APP_GROUPS')

    def test_existing_id_only_gets_its_missing_capability(self):
        self.assertEqual([path for path, method, _, _ in self.exercise(True, False) if method == 'POST'], ['bundleIdCapabilities'])


if __name__ == '__main__': unittest.main()
