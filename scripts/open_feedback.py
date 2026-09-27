#!/usr/bin/env python3
"""Decrypt a bundle written by asc_feedback.py into a folder.

Usage: open_feedback.py BUNDLE PRIVATE_KEY_PEM OUTPUT_DIR
"""
import io
import sys
import tarfile
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

MAGIC = b"TRADUCI1"


def open_bundle(blob: bytes, private_key_pem: bytes) -> bytes:
    if not blob.startswith(MAGIC):
        raise ValueError("not a Traduci feedback bundle")
    size = int.from_bytes(blob[8:10], "big")
    wrapped, nonce, sealed = blob[10:10 + size], blob[10 + size:22 + size], blob[22 + size:]
    private_key = serialization.load_pem_private_key(private_key_pem, password=None)
    key = private_key.decrypt(wrapped, padding.OAEP(mgf=padding.MGF1(hashes.SHA256()), algorithm=hashes.SHA256(), label=None))
    return AESGCM(key).decrypt(nonce, sealed, None)


def main() -> None:
    bundle, private_key, output = (Path(arg) for arg in sys.argv[1:4])
    archive = open_bundle(bundle.read_bytes(), private_key.read_bytes())
    output.mkdir(parents=True, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as tar:
        tar.extractall(output, filter="data")
    print(f"Opened {bundle} into {output}")


if __name__ == "__main__":
    main()
