"""Emit known-answer vectors for the C crypto as flipper/tests/vectors/bambu_keys.h.

SHA-256 (FIPS 180-2 examples plus padding boundaries), HMAC-SHA256 (all
RFC 4231 cases), HKDF-SHA256 (RFC 5869 cases 1-3) and Bambu Key A sets for
two UIDs from `bambu_keys.derive_keys`. `tests/test_bambu_keys.py` checks
the same tables in Python and fails when the header is stale.

Run from tools/: `uv run python -m fixtures.make_key_vectors`.
"""

import hashlib
from dataclasses import dataclass
from pathlib import Path

import bambu_keys

REPO = Path(__file__).resolve().parents[2]
OUTPUT = "flipper/tests/vectors/bambu_keys.h"


@dataclass(frozen=True)
class Sha256Vector:
    name: str
    message: bytes
    digest: str


@dataclass(frozen=True)
class HmacVector:
    name: str
    key: bytes
    data: bytes
    mac: str  # hex; RFC 4231 case 5 is truncated to 128 bits


@dataclass(frozen=True)
class HkdfVector:
    name: str
    ikm: bytes
    salt: bytes
    info: bytes
    okm: str


@dataclass(frozen=True)
class UidVector:
    uid: str
    keys: str  # 96 bytes, upper-case hex, sector 0 first


def _sha(name: str, message: bytes) -> Sha256Vector:
    return Sha256Vector(name, message, hashlib.sha256(message).hexdigest())


SHA256_VECTORS = [
    Sha256Vector(
        "empty", b"", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    ),
    Sha256Vector(
        "abc", b"abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    ),
    Sha256Vector(
        "fips_448_bit",
        b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
    ),
    Sha256Vector(
        "fips_896_bit",
        b"abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmn"
        b"hijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
        "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1",
    ),
    *[_sha(f"a_x{n}", b"a" * n) for n in (55, 56, 63, 64, 65, 119, 128)],
    _sha("bytes_0_to_255", bytes(range(256))),
]

SHA256_MILLION_A = "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"

_LARGE_KEY = b"\xaa" * 131

HMAC_VECTORS = [
    HmacVector(
        "rfc4231_case_1",
        b"\x0b" * 20,
        b"Hi There",
        "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
    ),
    HmacVector(
        "rfc4231_case_2",
        b"Jefe",
        b"what do ya want for nothing?",
        "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
    ),
    HmacVector(
        "rfc4231_case_3",
        b"\xaa" * 20,
        b"\xdd" * 50,
        "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe",
    ),
    HmacVector(
        "rfc4231_case_4",
        bytes(range(1, 26)),
        b"\xcd" * 50,
        "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b",
    ),
    HmacVector(
        "rfc4231_case_5",
        b"\x0c" * 20,
        b"Test With Truncation",
        "a3b6167473100ee06e0c796c2955552b",
    ),
    HmacVector(
        "rfc4231_case_6",
        _LARGE_KEY,
        b"Test Using Larger Than Block-Size Key - Hash Key First",
        "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54",
    ),
    HmacVector(
        "rfc4231_case_7",
        _LARGE_KEY,
        b"This is a test using a larger than block-size key and a larger than "
        b"block-size data. The key needs to be hashed before being used by the "
        b"HMAC algorithm.",
        "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2",
    ),
]

HKDF_VECTORS = [
    HkdfVector(
        "rfc5869_case_1",
        b"\x0b" * 22,
        bytes(range(0x0D)),
        bytes(range(0xF0, 0xFA)),
        "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf"
        "34007208d5b887185865",
    ),
    HkdfVector(
        "rfc5869_case_2",
        bytes(range(0x00, 0x50)),
        bytes(range(0x60, 0xB0)),
        bytes(range(0xB0, 0x100)),
        "b11e398dc80327a1c8e7f78c596a49344f012eda2d4efad8a050cc4c19afa97c"
        "59045a99cac7827271cb41c65e590e09da3275600c2f09b8367793a9aca3db71"
        "cc30c58179ec3e87c14c01d5c1f3434f1d87",
    ),
    HkdfVector(
        "rfc5869_case_3",
        b"\x0b" * 22,
        b"",
        b"",
        "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d"
        "9d201395faa4b61a96c8",
    ),
]

# The first UID is the one in protocol/fixtures/tags/bambu_pla_basic_synthetic.json.
UID_VECTORS = [
    UidVector(uid, b"".join(bambu_keys.derive_keys(bytes.fromhex(uid))).hex().upper())
    for uid in ("5A3C9E21", "04A1B2C3")
]


def c_string(data: bytes, indent: str) -> str:
    """Adjacent C string literals with every byte as a \\x escape, 16 per line."""
    if not data:
        return '""'
    chunks = [data[i : i + 16] for i in range(0, len(data), 16)]
    lines = ['"' + "".join(f"\\x{b:02x}" for b in chunk) + '"' for chunk in chunks]
    return ("\n" + indent).join(lines)


def c_bytes(data: bytes, indent: str) -> str:
    """Brace-enclosed byte list, 12 per line."""
    chunks = [data[i : i + 12] for i in range(0, len(data), 12)]
    lines = [", ".join(f"0x{b:02x}" for b in chunk) for chunk in chunks]
    return "{\n" + indent + ("," + "\n" + indent).join(lines) + ",\n" + indent[:-4] + "}"


def render() -> str:
    out = [
        "/* Generated by tools/fixtures/make_key_vectors.py; do not edit. */",
        "#pragma once",
        "",
        "#include <stddef.h>",
        "#include <stdint.h>",
        "",
        "typedef struct {",
        "    const char* name;",
        "    const char* message;",
        "    size_t message_len;",
        "    uint8_t digest[32];",
        "} Sha256Vector;",
        "",
        "typedef struct {",
        "    const char* name;",
        "    const char* key;",
        "    size_t key_len;",
        "    const char* data;",
        "    size_t data_len;",
        "    uint8_t mac[32];",
        "    size_t mac_len; /* bytes of mac to compare (case 5 is truncated) */",
        "} HmacVector;",
        "",
        "typedef struct {",
        "    const char* name;",
        "    const char* ikm;",
        "    size_t ikm_len;",
        "    const char* salt;",
        "    size_t salt_len;",
        "    const char* info;",
        "    size_t info_len;",
        "    uint8_t okm[82];",
        "    size_t okm_len;",
        "} HkdfVector;",
        "",
        "typedef struct {",
        "    uint8_t uid[4];",
        "    uint8_t keys[96];",
        "} BambuUidVector;",
        "",
    ]

    ind = " " * 12
    out.append("static const Sha256Vector SHA256_VECTORS[] = {")
    for v in SHA256_VECTORS:
        out += [
            "    {",
            f'        "{v.name}",',
            f"        {c_string(v.message, ind[:-4])},",
            f"        {len(v.message)},",
            f"        {c_bytes(bytes.fromhex(v.digest), ind)},",
            "    },",
        ]
    out += ["};", ""]

    million_a = c_bytes(bytes.fromhex(SHA256_MILLION_A), " " * 4)
    out.append(f"static const uint8_t SHA256_MILLION_A[32] = {million_a};")
    out.append("")

    out.append("static const HmacVector HMAC_VECTORS[] = {")
    for v in HMAC_VECTORS:
        mac = bytes.fromhex(v.mac)
        out += [
            "    {",
            f'        "{v.name}",',
            f"        {c_string(v.key, ind[:-4])},",
            f"        {len(v.key)},",
            f"        {c_string(v.data, ind[:-4])},",
            f"        {len(v.data)},",
            f"        {c_bytes(mac, ind)},",
            f"        {len(mac)},",
            "    },",
        ]
    out += ["};", ""]

    out.append("static const HkdfVector HKDF_VECTORS[] = {")
    for v in HKDF_VECTORS:
        okm = bytes.fromhex(v.okm)
        out += [
            "    {",
            f'        "{v.name}",',
            f"        {c_string(v.ikm, ind[:-4])},",
            f"        {len(v.ikm)},",
            f"        {c_string(v.salt, ind[:-4])},",
            f"        {len(v.salt)},",
            f"        {c_string(v.info, ind[:-4])},",
            f"        {len(v.info)},",
            f"        {c_bytes(okm, ind)},",
            f"        {len(okm)},",
            "    },",
        ]
    out += ["};", ""]

    out.append("static const BambuUidVector BAMBU_UID_VECTORS[] = {")
    for v in UID_VECTORS:
        out += [
            "    {",
            f"        {c_bytes(bytes.fromhex(v.uid), ind)},",
            f"        {c_bytes(bytes.fromhex(v.keys), ind)},",
            "    },",
        ]
    out += ["};", ""]

    for name, table in (
        ("SHA256_VECTOR_COUNT", "SHA256_VECTORS"),
        ("HMAC_VECTOR_COUNT", "HMAC_VECTORS"),
        ("HKDF_VECTOR_COUNT", "HKDF_VECTORS"),
        ("BAMBU_UID_VECTOR_COUNT", "BAMBU_UID_VECTORS"),
    ):
        out.append(f"#define {name} (sizeof({table}) / sizeof({table}[0]))")
    return "\n".join(out) + "\n"


def build() -> dict[str, str]:
    return {OUTPUT: render()}


if __name__ == "__main__":
    for relative, content in build().items():
        path = REPO / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        print(f"wrote {relative}")
