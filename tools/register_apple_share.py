#!/usr/bin/env python3
"""Prepare the one fixed Share App ID, without keys or team-wide inventories.

The existing App Group must also be assigned in the Developer account before
the first profile is created. No certificate or App Store record is created.
"""
from apple_signing import api, BUNDLE

SHARE = BUNDLE + '.share'


def prepare():
    matches = [item for item in api('bundleIds', query={'filter[identifier]': SHARE})['data']
               if item['attributes']['identifier'] == SHARE]
    if len(matches) > 1:
        raise RuntimeError('Cannot uniquely identify the fixed Share App ID')
    if matches:
        record = matches[0]
    else:
        record = api('bundleIds', 'POST', {'data': {'type': 'bundleIds', 'attributes': {
            'identifier': SHARE, 'name': 'Seafile Next Share', 'platform': 'UNIVERSAL',
        }}})['data']
    if record['attributes']['identifier'] != SHARE:
        raise RuntimeError('The returned Share App ID does not match the requested identifier')
    capabilities = api('bundleIds/' + record['id'] + '/bundleIdCapabilities', query={'limit': '200'})['data']
    if not any(item['attributes']['capabilityType'] == 'APP_GROUPS' for item in capabilities):
        api('bundleIdCapabilities', 'POST', {'data': {'type': 'bundleIdCapabilities',
            'attributes': {'capabilityType': 'APP_GROUPS'},
            'relationships': {'bundleId': {'data': {'type': 'bundleIds', 'id': record['id']}}}}})
    print('The fixed Share App ID is ready. Assign the existing project App Group before its first signed build.')


if __name__ == '__main__':
    prepare()
