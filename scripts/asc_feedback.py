#!/usr/bin/env python3
"""Fetch the app's TestFlight feedback and write it as an encrypted bundle.

The repository is public, so the bundle (comments, device details, downscaled screenshots and
crash logs; tester emails are dropped) is sealed with AES-256-GCM under a random key, and that
key is wrapped with RSA-OAEP for scripts/feedback_public_key.pem. Only the holder of the matching
private key can open it, with scripts/open_feedback.py. To hand the job to someone else, commit
their public key instead.

Usage: asc_feedback.py OUTPUT_FILE
Env: KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID, BUNDLE_ID. Needs PyJWT, cryptography and Pillow.
"""
import io
import json
import os
import sys
import tarfile
import urllib.error
import urllib.request
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from PIL import Image

from asc_preflight import call, fail, token

MAGIC = b"TRADUCI1"
PUBLIC_KEY = Path(__file__).with_name("feedback_public_key.pem")
# Everything useful for debugging; deliberately not "email".
KEEP = [
    "createdDate", "comment", "deviceModel", "deviceFamily", "osVersion", "locale", "timeZone",
    "connectionType", "batteryPercentage", "appUptimeInMilliseconds", "screenWidthInPoints",
    "screenHeightInPoints", "buildBundleId", "architecture",
]


def pages(path: str) -> list[dict]:
    response = call("GET", path, {"limit": 50})
    items = list(response["data"])
    while response.get("links", {}).get("next"):
        response = call("GET", response["links"]["next"])
        items += response["data"]
    return items


def download(url: str) -> bytes:
    try:
        with urllib.request.urlopen(url, timeout=60) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        if error.code not in (401, 403):
            raise
        request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token()}"})
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.read()


def screenshot_jpeg(shot: dict) -> bytes:
    url = shot.get("url") or shot["templateUrl"].format(w=shot.get("width", 1000), h=shot.get("height", 2000), f="png")
    image = Image.open(io.BytesIO(download(url))).convert("RGB")
    image.thumbnail((1000, 1000))  # plenty to judge overlays, small enough to keep the bundle light
    out = io.BytesIO()
    image.save(out, "JPEG", quality=70)
    return out.getvalue()


def collect(app_id: str) -> dict[str, bytes]:
    files: dict[str, bytes] = {}
    entries = []

    for item in pages(f"apps/{app_id}/betaFeedbackScreenshotSubmissions"):
        attributes = item.get("attributes", {})
        entry = {"id": item["id"], "kind": "feedback", **{k: attributes.get(k) for k in KEEP}, "screenshots": []}
        for index, shot in enumerate(attributes.get("screenshots") or []):
            name = f"{item['id']}-{index}.jpg"
            try:
                files[name] = screenshot_jpeg(shot)
                entry["screenshots"].append(name)
            except Exception as error:  # one bad image shouldn't lose the rest of the feedback
                entry["screenshots"].append(f"unavailable: {error}")
        entries.append(entry)

    for item in pages(f"apps/{app_id}/betaFeedbackCrashSubmissions"):
        attributes = item.get("attributes", {})
        entry = {"id": item["id"], "kind": "crash", **{k: attributes.get(k) for k in KEEP}}
        try:
            log = call("GET", f"betaFeedbackCrashSubmissions/{item['id']}/crashLog")["data"]["attributes"]
            files[f"{item['id']}.crash"] = (log.get("logText") or "").encode()
            entry["crashLog"] = f"{item['id']}.crash"
        except SystemExit:  # call() reports API errors by exiting; keep going without the log
            entry["crashLog"] = "unavailable"
        entries.append(entry)

    entries.sort(key=lambda entry: entry.get("createdDate") or "")
    files["feedback.json"] = json.dumps(entries, indent=2, ensure_ascii=False).encode()
    return files


def seal(files: dict[str, bytes]) -> bytes:
    archive = io.BytesIO()
    with tarfile.open(fileobj=archive, mode="w:gz") as tar:
        for name, data in files.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    public_key = serialization.load_pem_public_key(PUBLIC_KEY.read_bytes())
    key = AESGCM.generate_key(bit_length=256)
    nonce = os.urandom(12)
    wrapped = public_key.encrypt(key, padding.OAEP(mgf=padding.MGF1(hashes.SHA256()), algorithm=hashes.SHA256(), label=None))
    return MAGIC + len(wrapped).to_bytes(2, "big") + wrapped + nonce + AESGCM(key).encrypt(nonce, archive.getvalue(), None)


def main() -> None:
    output = Path(sys.argv[1])
    bundle_id = os.environ["BUNDLE_ID"]
    apps = call("GET", "apps", {"filter[bundleId]": bundle_id})["data"]
    if not apps:
        fail(f"No App Store Connect app uses {bundle_id}.")
    files = collect(apps[0]["id"])
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(seal(files))
    count = len(json.loads(files["feedback.json"]))
    print(f"Sealed {count} feedback item(s) and {len(files) - 1} attachment(s) into {output}.")


if __name__ == "__main__":
    main()
