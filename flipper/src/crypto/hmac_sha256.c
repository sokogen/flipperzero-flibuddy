#include "hmac_sha256.h"

#include <string.h>

void sb_hmac_sha256_init(SbHmacSha256* ctx, const uint8_t* key, size_t key_len) {
    uint8_t block[SB_SHA256_BLOCK_LEN] = {0};
    if(key_len > SB_SHA256_BLOCK_LEN) {
        sb_sha256(key, key_len, block);
    } else if(key_len > 0) {
        memcpy(block, key, key_len);
    }

    uint8_t pad[SB_SHA256_BLOCK_LEN];
    for(size_t i = 0; i < SB_SHA256_BLOCK_LEN; i++) pad[i] = block[i] ^ 0x36;
    sb_sha256_init(&ctx->inner);
    sb_sha256_update(&ctx->inner, pad, sizeof(pad));

    for(size_t i = 0; i < SB_SHA256_BLOCK_LEN; i++) pad[i] = block[i] ^ 0x5c;
    sb_sha256_init(&ctx->outer);
    sb_sha256_update(&ctx->outer, pad, sizeof(pad));

    memset(block, 0, sizeof(block));
    memset(pad, 0, sizeof(pad));
}

void sb_hmac_sha256_update(SbHmacSha256* ctx, const uint8_t* data, size_t len) {
    sb_sha256_update(&ctx->inner, data, len);
}

void sb_hmac_sha256_final(SbHmacSha256* ctx, uint8_t out[SB_SHA256_DIGEST_LEN]) {
    uint8_t inner[SB_SHA256_DIGEST_LEN];
    sb_sha256_final(&ctx->inner, inner);
    sb_sha256_update(&ctx->outer, inner, sizeof(inner));
    sb_sha256_final(&ctx->outer, out);
    memset(inner, 0, sizeof(inner));
}

void sb_hmac_sha256(
    const uint8_t* key,
    size_t key_len,
    const uint8_t* data,
    size_t data_len,
    uint8_t out[SB_SHA256_DIGEST_LEN]) {
    SbHmacSha256 ctx;
    sb_hmac_sha256_init(&ctx, key, key_len);
    sb_hmac_sha256_update(&ctx, data, data_len);
    sb_hmac_sha256_final(&ctx, out);
}
