"""Bambu Lab MIFARE Classic Key A derivation.

Port of `hkdf_derive_keys` from the SpoolBuddy daemon (`pn5180.py`):
HKDF-SHA256 with the Bambu master key as salt, the 4-byte UID as input key
material and "RFID-A\\0" as info; 96 bytes of output are 16 six-byte keys,
one per sector.
"""

import hashlib
import hmac

MASTER_KEY = bytes.fromhex("9A759CF2C4F7CAFF222CB9769B41BC96")
INFO = b"RFID-A\0"
SECTORS = 16
KEY_LEN = 6


def hkdf_sha256(salt: bytes, ikm: bytes, info: bytes, length: int) -> bytes:
    """RFC 5869 HKDF with SHA-256 (extract, then expand to `length` bytes)."""
    if not 0 < length <= 255 * 32:
        raise ValueError("length out of range")
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    okm = b""
    block = b""
    counter = 1
    while len(okm) < length:
        block = hmac.new(prk, block + info + bytes([counter]), hashlib.sha256).digest()
        okm += block
        counter += 1
    return okm[:length]


def derive_keys(uid: bytes) -> list[bytes]:
    """Return the 16 sector Key A values for a 4-byte UID."""
    if len(uid) != 4:
        raise ValueError("Bambu tags have a 4-byte UID")
    okm = hkdf_sha256(MASTER_KEY, uid, INFO, SECTORS * KEY_LEN)
    return [okm[i * KEY_LEN : (i + 1) * KEY_LEN] for i in range(SECTORS)]
