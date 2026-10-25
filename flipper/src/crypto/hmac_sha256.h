/* HMAC-SHA256 (RFC 2104) on top of sb_sha256. */
#pragma once

#include "sha256.h"

typedef struct {
    SbSha256 inner;
    SbSha256 outer;
} SbHmacSha256;

void sb_hmac_sha256_init(SbHmacSha256* ctx, const uint8_t* key, size_t key_len);
void sb_hmac_sha256_update(SbHmacSha256* ctx, const uint8_t* data, size_t len);
void sb_hmac_sha256_final(SbHmacSha256* ctx, uint8_t out[SB_SHA256_DIGEST_LEN]);

/* One-shot MAC; `key` may be NULL when `key_len` is 0. */
void sb_hmac_sha256(
    const uint8_t* key,
    size_t key_len,
    const uint8_t* data,
    size_t data_len,
    uint8_t out[SB_SHA256_DIGEST_LEN]);
