/* SHA-256 (FIPS 180-4). Small, no dynamic allocation. The firmware does not
 * export mbedtls hashing to FAPs, so the app ships its own. */
#pragma once

#include <stddef.h>
#include <stdint.h>

#define SB_SHA256_DIGEST_LEN 32
#define SB_SHA256_BLOCK_LEN 64

typedef struct {
    uint32_t state[8];
    uint64_t total_len; /* bytes hashed so far */
    uint8_t block[SB_SHA256_BLOCK_LEN];
    size_t block_len; /* bytes buffered in block */
} SbSha256;

void sb_sha256_init(SbSha256* ctx);
void sb_sha256_update(SbSha256* ctx, const uint8_t* data, size_t len);
void sb_sha256_final(SbSha256* ctx, uint8_t out[SB_SHA256_DIGEST_LEN]);

/* One-shot digest of `len` bytes. */
void sb_sha256(const void* data, size_t len, uint8_t out[SB_SHA256_DIGEST_LEN]);
