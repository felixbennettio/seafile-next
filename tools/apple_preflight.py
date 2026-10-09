#!/usr/bin/env python3
"""Check App Store Connect access without printing credentials."""
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt
from apple_testflight import internal_group, add_internal_tester


def main():
    token = jwt.encode({"iss": os.environ["APP_STORE_CONNECT_ISSUER_ID"], "iat": int(time.time()), "exp": int(time.time()) + 600, "aud": "appstoreconnect-v1"}, os.environ["APP_STORE_CONNECT_PRIVATE_KEY"], algorithm="ES256", headers={"kid": os.environ["APP_STORE_CONNECT_KEY_ID"]})
    print(f"::add-mask::{token}")
    identifier = os.environ.get("APPLE_BUNDLE_ID", "io.felixbennett.seafile")
    results = {}
    queries = {
        "apps": ("apps", {"filter[bundleId]": identifier}),
        "bundleIds": ("bundleIds", {"filter[identifier]": identifier}),
    }
    for name, (endpoint, params) in queries.items():
        url = "https://api.appstoreconnect.apple.com/v1/" + endpoint + "?" + urllib.parse.urlencode(params)
        request = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                data = json.load(response)["data"]
        except urllib.error.HTTPError as error:
            print(f"::error::App Store Connect {endpoint} returned HTTP {error.code}")
            raise SystemExit(1) from None
        fields = {"apps": ("bundleId",), "bundleIds": ("identifier", "platform")}[name]
        results[name] = [{"id": entry["id"], **{field: entry["attributes"].get(field) for field in fields}} for entry in data]
    print(json.dumps(results, indent=2))
    if not results["apps"] or not results["bundleIds"]:
        raise SystemExit("The API key cannot see the requested App record and registered Bundle ID")
    app_id = results["apps"][0]["id"]
    request = urllib.request.Request(f"https://api.appstoreconnect.apple.com/v1/apps/{app_id}/appInfos", headers={"Authorization": "Bearer " + token})
    with urllib.request.urlopen(request, timeout=30) as response:
        print("App platform record count:", len(json.load(response)["data"]))
    request = urllib.request.Request(f"https://api.appstoreconnect.apple.com/v1/apps/{app_id}/betaGroups?limit=200", headers={"Authorization": "Bearer " + token})
    with urllib.request.urlopen(request, timeout=30) as response:
        groups = json.load(response)["data"]
    print("TestFlight groups:", json.dumps([{ "id": item["id"], **{key: item["attributes"].get(key) for key in ("isInternalGroup", "hasAccessToAllBuilds", "publicLinkEnabled")} } for item in groups], indent=2))
    if os.environ.get('APPLE_PREPARE_TESTFLIGHT') == 'true':
        internal_group(app_id)
        if os.environ.get('APPLE_INTERNAL_TESTER_EMAIL'):
            add_internal_tester(app_id, os.environ['APPLE_INTERNAL_TESTER_EMAIL'])


if __name__ == "__main__":
    main()
