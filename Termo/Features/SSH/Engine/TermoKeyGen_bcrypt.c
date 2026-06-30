//  bcrypt_pbkdf —— OpenSSH 加密私钥的 KDF（替代 ssh-keygen 的加密路径）。
//  Blowfish 实现 vendored 自 libssh2 携带的 OpenBSD 公有领域 blowfish.c（termo_blowfish.h）；
//  bcrypt_pbkdf / bcrypt_hash 移植自 OpenBSD bcrypt_pbkdf.c，SHA512 改用 OpenSSL。
//  导出 termo_bcrypt_pbkdf 供 TermoKeyGen.c 的 OpenSSH ed25519 加密封装调用。
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>

#include <openssl/sha.h>
#include <openssl/crypto.h>

#define LIBSSH2_BCRYPT_PBKDF_C 1     // 启用 termo_blowfish.h 内的实现守卫
#include "termo_blowfish.h"          // blf_ctx + Blowfish_initstate/expandstate/expand0state + blf_enc（均 static）

#define BCRYPT_BLOCKS 8
#define BCRYPT_HASHSIZE (BCRYPT_BLOCKS * 4)   // 32
#ifndef SHA512_DIGEST_LENGTH
#define SHA512_DIGEST_LENGTH 64
#endif

static void bcrypt_hash(uint8_t *sha2pass, uint8_t *sha2salt, uint8_t *out) {
    blf_ctx state;
    uint8_t ciphertext[BCRYPT_HASHSIZE] = {
        'O','x','y','c','h','r','o','m','a','t','i','c',
        'B','l','o','w','f','i','s','h',
        'S','w','a','t',
        'D','y','n','a','m','i','t','e' };
    uint32_t cdata[BCRYPT_BLOCKS];
    int i;
    uint16_t j;
    uint16_t shalen = SHA512_DIGEST_LENGTH;

    /* key expansion */
    Blowfish_initstate(&state);
    Blowfish_expandstate(&state, sha2salt, shalen, sha2pass, shalen);
    for(i = 0; i < 64; i++) {
        Blowfish_expand0state(&state, sha2salt, shalen);
        Blowfish_expand0state(&state, sha2pass, shalen);
    }

    /* encryption */
    j = 0;
    for(i = 0; i < BCRYPT_BLOCKS; i++)
        cdata[i] = Blowfish_stream2word(ciphertext, sizeof(ciphertext), &j);
    for(i = 0; i < 64; i++)
        blf_enc(&state, cdata, BCRYPT_BLOCKS / 2);

    /* copy out (little-endian) */
    for(i = 0; i < BCRYPT_BLOCKS; i++) {
        out[4 * i + 3] = (uint8_t)((cdata[i] >> 24) & 0xff);
        out[4 * i + 2] = (uint8_t)((cdata[i] >> 16) & 0xff);
        out[4 * i + 1] = (uint8_t)((cdata[i] >> 8) & 0xff);
        out[4 * i + 0] = (uint8_t)(cdata[i] & 0xff);
    }

    OPENSSL_cleanse(ciphertext, sizeof(ciphertext));
    OPENSSL_cleanse(cdata, sizeof(cdata));
    OPENSSL_cleanse(&state, sizeof(state));
}

int termo_bcrypt_pbkdf(const char *pass, size_t passlen, const uint8_t *salt, size_t saltlen,
                       uint8_t *key, size_t keylen, unsigned int rounds) {
    uint8_t sha2pass[SHA512_DIGEST_LENGTH];
    uint8_t sha2salt[SHA512_DIGEST_LENGTH];
    uint8_t out[BCRYPT_HASHSIZE];
    uint8_t tmpout[BCRYPT_HASHSIZE];
    uint8_t *countsalt;
    size_t i, j, amt, stride;
    uint32_t count;
    size_t origkeylen = keylen;

    if(rounds < 1) return -1;
    if(passlen == 0 || saltlen == 0 || keylen == 0 ||
       keylen > sizeof(out) * sizeof(out) || saltlen > 1 << 20)
        return -1;
    countsalt = calloc(1, saltlen + 4);
    if(!countsalt) return -1;
    stride = (keylen + sizeof(out) - 1) / sizeof(out);
    amt = (keylen + stride - 1) / stride;

    memcpy(countsalt, salt, saltlen);

    /* collapse password */
    SHA512((const unsigned char *)pass, passlen, sha2pass);

    for(count = 1; keylen > 0; count++) {
        countsalt[saltlen + 0] = (uint8_t)((count >> 24) & 0xff);
        countsalt[saltlen + 1] = (uint8_t)((count >> 16) & 0xff);
        countsalt[saltlen + 2] = (uint8_t)((count >> 8) & 0xff);
        countsalt[saltlen + 3] = (uint8_t)(count & 0xff);

        SHA512(countsalt, saltlen + 4, sha2salt);
        bcrypt_hash(sha2pass, sha2salt, tmpout);
        memcpy(out, tmpout, sizeof(out));

        for(i = 1; i < rounds; i++) {
            SHA512(tmpout, sizeof(tmpout), sha2salt);
            bcrypt_hash(sha2pass, sha2salt, tmpout);
            for(j = 0; j < sizeof(out); j++)
                out[j] ^= tmpout[j];
        }

        /* pbkdf2 deviation: 非线性分布输出 */
        amt = (amt < keylen) ? amt : keylen;
        for(i = 0; i < amt; i++) {
            size_t dest = i * stride + (count - 1);
            if(dest >= origkeylen) break;
            key[dest] = out[i];
        }
        keylen -= i;
    }

    OPENSSL_cleanse(out, sizeof(out));
    OPENSSL_cleanse(sha2pass, sizeof(sha2pass));
    OPENSSL_cleanse(sha2salt, sizeof(sha2salt));
    free(countsalt);
    return 0;
}
