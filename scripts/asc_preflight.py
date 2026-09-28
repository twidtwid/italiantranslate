#!/usr/bin/env python3
"""Pre-flight for TestFlight uploads, using the App Store Connect API.

1. Proves the API key works.
2. Registers the app's bundle ID if it isn't registered yet.
3. Stops with instructions if the App Store Connect app record is missing:
   Apple only allows creating that on the website.

Env: KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID, BUNDLE_ID. Needs PyJWT + cryptography.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt

API = "https://api.appstoreconnect.apple.com/v1"


def token() -> str:
    with open(os.environ["KEY_PATH"]) as f:
        key = f.read()
    now = int(time.time())
    claims = {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}
    return jwt.encode(claims, key, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"]})


def call(method: str, path: str, params: dict | None = None, body: dict | None = None) -> dict:
    url = path if path.startswith("https://") else f"{API}/{path}"  # full URLs: pagination links
    url += "?" + urllib.parse.urlencode(params) if params else ""
    request = urllib.request.Request(
        url,
        data=json.dumps(body).encode() if body is not None else None,
        method=method,
        headers={"Authorization": f"Bearer {token()}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        hint = ""
        if error.code == 401:
            hint = " Check ASC_KEY_ID, ASC_ISSUER_ID and ASC_PRIVATE_KEY (the whole .p8 file, BEGIN/END lines included)."
        elif error.code == 403:
            hint = " The API key needs the Admin role."
        fail(f"App Store Connect said {error.code} to {method} /{path}.{hint} Details: {detail}")
    except urllib.error.URLError as error:
        fail(f"Couldn't reach App Store Connect: {error.reason}")


def fail(message: str) -> None:
    print(f"::error::{message}")
    sys.exit(1)


def main() -> None:
    bundle_id = os.environ["BUNDLE_ID"]

    registered = call("GET", "bundleIds", {"filter[identifier]": bundle_id, "limit": 200})["data"]
    if any(item["attributes"]["identifier"] == bundle_id for item in registered):
        print(f"Bundle ID {bundle_id} is registered.")
    else:
        call("POST", "bundleIds", body={"data": {"type": "bundleIds", "attributes": {
            "identifier": bundle_id, "name": "Traduci", "platform": "IOS"}}})
        print(f"Registered bundle ID {bundle_id}.")

    apps = call("GET", "apps", {"filter[bundleId]": bundle_id})["data"]
    if not apps:
        fail(
            f"No App Store Connect app uses {bundle_id} yet, and Apple only lets you create one on the web: "
            "appstoreconnect.apple.com > Apps > + > New App > iOS, any unique name (e.g. 'Traduci Live'), "
            f"Bundle ID {bundle_id}, any SKU. Then run this workflow again."
        )
    print(f"App record found: {apps[0]['attributes'].get('name')}. Ready to upload.")


if __name__ == "__main__":
    main()
