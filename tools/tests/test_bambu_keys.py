"""Known-answer vectors for the Bambu key derivation and its primitives.

The same vectors are emitted into flipper/tests/vectors/bambu_keys.h by
`fixtures.make_key_vectors`, so the C implementation is checked against
exactly what is asserted here.
"""

import hashlib
import hmac
from pathlib import Path

import pytest

import bambu_keys
from fixtures import make_key_vectors

REPO = Path(__file__).resolve().parents[2]


@pytest.mark.parametrize("vector", make_key_vectors.SHA256_VECTORS, ids=lambda v: v.name)
def test_sha256_vector(vector):
    assert hashlib.sha256(vector.message).hexdigest() == vector.digest


def test_sha256_known_answers_are_pinned():
    digests = {v.name: v.digest for v in make_key_vectors.SHA256_VECTORS}
    assert digests["empty"] == (
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    )
    assert digests["abc"] == (
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )
    assert make_key_vectors.SHA256_MILLION_A == (
        "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
    )
    assert hashlib.sha256(b"a" * 1_000_000).hexdigest() == make_key_vectors.SHA256_MILLION_A


def test_sha256_vectors_cover_padding_boundaries():
    lengths = {len(v.message) for v in make_key_vectors.SHA256_VECTORS}
    assert {0, 55, 56, 63, 64, 65, 119, 128} <= lengths


@pytest.mark.parametrize("vector", make_key_vectors.HMAC_VECTORS, ids=lambda v: v.name)
def test_hmac_rfc4231_vector(vector):
    mac = hmac.new(vector.key, vector.data, hashlib.sha256).hexdigest()
    assert mac[: len(vector.mac)] == vector.mac


def test_hmac_vectors_are_all_rfc4231_cases():
    assert [v.name for v in make_key_vectors.HMAC_VECTORS] == [
        f"rfc4231_case_{i}" for i in range(1, 8)
    ]


@pytest.mark.parametrize("vector", make_key_vectors.HKDF_VECTORS, ids=lambda v: v.name)
def test_hkdf_rfc5869_vector(vector):
    okm = bambu_keys.hkdf_sha256(vector.salt, vector.ikm, vector.info, len(vector.okm) // 2)
    assert okm.hex() == vector.okm


def test_hkdf_rejects_bad_lengths():
    with pytest.raises(ValueError):
        bambu_keys.hkdf_sha256(b"", b"x", b"", 0)
    with pytest.raises(ValueError):
        bambu_keys.hkdf_sha256(b"", b"x", b"", 255 * 32 + 1)


def test_uid_vectors_match_derive_keys():
    assert len(make_key_vectors.UID_VECTORS) == 2
    for vector in make_key_vectors.UID_VECTORS:
        keys = bambu_keys.derive_keys(bytes.fromhex(vector.uid))
        assert len(keys) == 16
        assert b"".join(keys).hex().upper() == vector.keys


def test_uid_vectors_are_pinned():
    """Regression pin: a change to the derivation must be deliberate."""
    keys = {v.uid: v.keys for v in make_key_vectors.UID_VECTORS}
    assert keys["5A3C9E21"].startswith("9BDCBF4850C3D72132E56D89")
    assert keys["5A3C9E21"].endswith("7A6B59D54099FED579F5156422C7081D44333EB2")
    assert keys["04A1B2C3"].startswith("2235AEC2322CBF605B2807A0")
    assert keys["04A1B2C3"].endswith("D24CB687539E181AD5F3FFA23477E0D9")


def test_uid_vector_uses_the_bambu_fixture_uid():
    assert make_key_vectors.UID_VECTORS[0].uid == "5A3C9E21"


def test_derivation_parameters():
    assert bambu_keys.MASTER_KEY.hex().upper() == "9A759CF2C4F7CAFF222CB9769B41BC96"
    assert bambu_keys.INFO == b"RFID-A\x00"


def test_c_header_is_current():
    outputs = make_key_vectors.build()
    assert list(outputs) == ["flipper/tests/vectors/bambu_keys.h"]
    for relative, content in outputs.items():
        assert (REPO / relative).read_text(encoding="utf-8") == content, (
            f"{relative} is stale; regenerate with "
            "`uv run python -m fixtures.make_key_vectors`"
        )


def test_c_header_has_no_long_lines():
    (content,) = make_key_vectors.build().values()
    assert all(len(line) <= 100 for line in content.splitlines())
