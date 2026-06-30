//  进程内 SSH 密钥生成 / 导入（OpenSSL EVP + 手写 OpenSSH 私钥格式，替代 spawn ssh-keygen）。
//  ed25519 私钥用 OpenSSH 格式（libssh2 的 fromfile 路径只认这个）；RSA 用 OpenSSL PKCS#8 PEM。
//  公钥行与指纹自行从密钥构造。加密 ed25519（bcrypt）见 TermoKeyGen_bcrypt.c。
#include "TermoSSHCore.h"

#include <string.h>
#include <stdlib.h>
#include <stdio.h>

#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/bio.h>
#include <openssl/sha.h>
#include <openssl/rand.h>
#include <openssl/bn.h>
#include <openssl/core_names.h>

// 前向声明
static int kb64_decode_seg(const char *src, size_t srclen, unsigned char *out, size_t out_cap);
static int parse_openssh_pub(const unsigned char *p, size_t len, char *out_pub, int pub_cap,
                             int *out_type, int *out_encrypted);

// ── base64（标准，补 '='）──────────────────────────────────────────────────
static const char KB64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static char *kb64_encode(const unsigned char *src, size_t len) {  // 调用方 free
    size_t out = ((len + 2) / 3) * 4;
    char *dst = malloc(out + 1);
    if (!dst) return NULL;
    size_t i = 0, o = 0;
    while (i + 3 <= len) {
        unsigned v = (src[i] << 16) | (src[i+1] << 8) | src[i+2];
        dst[o++] = KB64[(v>>18)&63]; dst[o++] = KB64[(v>>12)&63];
        dst[o++] = KB64[(v>>6)&63];  dst[o++] = KB64[v&63];
        i += 3;
    }
    size_t rem = len - i;
    if (rem == 1) {
        unsigned v = src[i] << 16;
        dst[o++] = KB64[(v>>18)&63]; dst[o++] = KB64[(v>>12)&63];
        dst[o++] = '='; dst[o++] = '=';
    } else if (rem == 2) {
        unsigned v = (src[i] << 16) | (src[i+1] << 8);
        dst[o++] = KB64[(v>>18)&63]; dst[o++] = KB64[(v>>12)&63];
        dst[o++] = KB64[(v>>6)&63];  dst[o++] = '=';
    }
    dst[o] = '\0';
    return dst;
}
// ── SSH wire 缓冲（大端）──────────────────────────────────────────────────
typedef struct { unsigned char *d; size_t len, cap; } wbuf;
static int wb_need(wbuf *b, size_t n) {
    if (b->len + n <= b->cap) return 0;
    size_t nc = b->cap ? b->cap : 256;
    while (nc < b->len + n) nc *= 2;
    unsigned char *nd = realloc(b->d, nc);
    if (!nd) return -1;
    b->d = nd; b->cap = nc; return 0;
}
static void wb_free(wbuf *b) { free(b->d); b->d = NULL; b->len = b->cap = 0; }
static int wb_u32(wbuf *b, unsigned v) {
    if (wb_need(b, 4)) return -1;
    b->d[b->len++] = (v>>24)&0xFF; b->d[b->len++] = (v>>16)&0xFF;
    b->d[b->len++] = (v>>8)&0xFF;  b->d[b->len++] = v&0xFF; return 0;
}
static int wb_bytes(wbuf *b, const unsigned char *p, size_t n) {
    if (wb_need(b, n)) return -1; memcpy(b->d + b->len, p, n); b->len += n; return 0;
}
static int wb_str(wbuf *b, const unsigned char *p, size_t n) {  // u32 len + 数据
    if (wb_u32(b, (unsigned)n)) return -1; return wb_bytes(b, p, n);
}
static int wb_cstr(wbuf *b, const char *s) { return wb_str(b, (const unsigned char *)s, strlen(s)); }
// mpint：大端正整数，最高位置 1 时前补 0x00。
static int wb_mpint(wbuf *b, const BIGNUM *bn) {
    int n = BN_num_bytes(bn);
    unsigned char *tmp = malloc(n ? n : 1);
    if (!tmp) return -1;
    BN_bn2bin(bn, tmp);
    int pad = (n > 0 && (tmp[0] & 0x80)) ? 1 : 0;
    if (wb_u32(b, (unsigned)(n + pad))) { free(tmp); return -1; }
    if (pad) { unsigned char z = 0; if (wb_bytes(b, &z, 1)) { free(tmp); return -1; } }
    int rc = wb_bytes(b, tmp, n);
    free(tmp);
    return rc;
}

// ── 公钥 blob / 行 / 指纹 ──────────────────────────────────────────────────
// 构造 SSH 公钥 wire blob。成功置 *out/*out_len（调用方 free）。
static int pub_blob(EVP_PKEY *pk, int is_ed, unsigned char **out, size_t *out_len) {
    wbuf b = {0};
    if (is_ed) {
        unsigned char pub[32]; size_t pl = sizeof(pub);
        if (EVP_PKEY_get_raw_public_key(pk, pub, &pl) != 1 || pl != 32) { wb_free(&b); return -1; }
        if (wb_cstr(&b, "ssh-ed25519") || wb_str(&b, pub, 32)) { wb_free(&b); return -1; }
    } else {
        BIGNUM *n = NULL, *e = NULL;
        if (EVP_PKEY_get_bn_param(pk, OSSL_PKEY_PARAM_RSA_N, &n) != 1 ||
            EVP_PKEY_get_bn_param(pk, OSSL_PKEY_PARAM_RSA_E, &e) != 1) {
            BN_free(n); BN_free(e); wb_free(&b); return -1;
        }
        int rc = wb_cstr(&b, "ssh-rsa") || wb_mpint(&b, e) || wb_mpint(&b, n);
        BN_free(n); BN_free(e);
        if (rc) { wb_free(&b); return -1; }
    }
    *out = b.d; *out_len = b.len;   // 移交所有权
    return 0;
}
// "SHA256:base64(去尾=)" 写入 out。
static void fp_from_blob(const unsigned char *blob, size_t len, char *out, int cap) {
    unsigned char h[32]; SHA256(blob, len, h);
    char *b64 = kb64_encode(h, 32);
    if (!b64) { if (cap) out[0] = '\0'; return; }
    size_t n = strlen(b64); while (n > 0 && b64[n-1] == '=') b64[--n] = '\0';
    snprintf(out, (size_t)cap, "SHA256:%s", b64);
    free(b64);
}
// "ssh-xxx base64blob[ comment]" 写入 out。
static void publine_from_blob(const unsigned char *blob, size_t len, const char *type,
                              const char *comment, char *out, int cap) {
    char *b64 = kb64_encode(blob, len);
    if (!b64) { if (cap) out[0] = '\0'; return; }
    if (comment && *comment) snprintf(out, (size_t)cap, "%s %s %s", type, b64, comment);
    else snprintf(out, (size_t)cap, "%s %s", type, b64);
    free(b64);
}

// ── OpenSSH 私钥容器封装（base64 + PEM 包裹）─────────────────────────────────
// 把 openssh-key-v1 完整二进制 base64 后按 70 列折行，包进 BEGIN/END。out 由调用方 free。
static char *openssh_pem_wrap(const unsigned char *bin, size_t len) {
    char *b64 = kb64_encode(bin, len);
    if (!b64) return NULL;
    size_t bl = strlen(b64);
    size_t lines = (bl + 69) / 70;
    size_t cap = 64 + bl + lines + 64;
    char *out = malloc(cap);
    if (!out) { free(b64); return NULL; }
    size_t o = 0;
    o += (size_t)snprintf(out + o, cap - o, "-----BEGIN OPENSSH PRIVATE KEY-----\n");
    for (size_t i = 0; i < bl; i += 70) {
        size_t n = bl - i < 70 ? bl - i : 70;
        memcpy(out + o, b64 + i, n); o += n; out[o++] = '\n';
    }
    o += (size_t)snprintf(out + o, cap - o, "-----END OPENSSH PRIVATE KEY-----\n");
    out[o] = '\0';
    free(b64);
    return out;
}

// 由 bcrypt 模块实现：用口令 + salt 派生 key||iv（48 字节），rounds 轮。返回 0 成功。
int termo_bcrypt_pbkdf(const char *pass, size_t passlen, const unsigned char *salt, size_t saltlen,
                       unsigned char *out, size_t outlen, unsigned int rounds);

// 组 ed25519 OpenSSH 私钥（passphrase 非空时 aes256-ctr + bcrypt 加密）。out 由调用方 free。
static char *build_openssh_ed25519(const unsigned char *pubblob, size_t publen,
                                   const unsigned char *seed32, const unsigned char *pub32,
                                   const char *comment, const char *passphrase, char *err, int errlen) {
    int encrypt = (passphrase && *passphrase) ? 1 : 0;
    unsigned char salt[16]; unsigned int rounds = 16;
    unsigned char keyiv[48];   // 32 key + 16 iv
    if (encrypt) {
        if (RAND_bytes(salt, sizeof(salt)) != 1) { snprintf(err, errlen, "随机数失败"); return NULL; }
        if (termo_bcrypt_pbkdf(passphrase, strlen(passphrase), salt, sizeof(salt),
                               keyiv, sizeof(keyiv), rounds) != 0) {
            snprintf(err, errlen, "bcrypt 派生失败"); return NULL;
        }
    }
    int block = encrypt ? 16 : 8;

    // 私有段（加密前）
    wbuf priv = {0};
    unsigned int checkint;
    if (RAND_bytes((unsigned char *)&checkint, 4) != 1) { snprintf(err, errlen, "随机数失败"); wb_free(&priv); return NULL; }
    unsigned char priv64[64]; memcpy(priv64, seed32, 32); memcpy(priv64 + 32, pub32, 32);
    if (wb_u32(&priv, checkint) || wb_u32(&priv, checkint) ||
        wb_cstr(&priv, "ssh-ed25519") || wb_str(&priv, pub32, 32) || wb_str(&priv, priv64, 64) ||
        wb_cstr(&priv, comment ? comment : "")) { wb_free(&priv); snprintf(err, errlen, "组装失败"); return NULL; }
    // padding 1,2,3,... 到 block 边界
    unsigned char padv = 1;
    while (priv.len % (size_t)block != 0) { if (wb_bytes(&priv, &padv, 1)) { wb_free(&priv); return NULL; } padv++; }

    if (encrypt) {   // aes-256-ctr 加密私有段
        EVP_CIPHER_CTX *c = EVP_CIPHER_CTX_new();
        int ol = 0;
        if (!c || EVP_EncryptInit_ex(c, EVP_aes_256_ctr(), NULL, keyiv, keyiv + 32) != 1 ||
            EVP_EncryptUpdate(c, priv.d, &ol, priv.d, (int)priv.len) != 1) {
            if (c) EVP_CIPHER_CTX_free(c); wb_free(&priv); snprintf(err, errlen, "加密失败"); return NULL;
        }
        EVP_CIPHER_CTX_free(c);
    }

    // 顶层容器
    wbuf top = {0};
    static const char magic[] = "openssh-key-v1";   // 含结尾 \0 共 15 字节
    if (wb_bytes(&top, (const unsigned char *)magic, sizeof(magic)) ||
        wb_cstr(&top, encrypt ? "aes256-ctr" : "none") ||
        wb_cstr(&top, encrypt ? "bcrypt" : "none")) { wb_free(&top); wb_free(&priv); return NULL; }
    if (encrypt) {
        wbuf kdf = {0};
        if (wb_str(&kdf, salt, sizeof(salt)) || wb_u32(&kdf, rounds) ||
            wb_str(&top, kdf.d, kdf.len)) { wb_free(&kdf); wb_free(&top); wb_free(&priv); return NULL; }
        wb_free(&kdf);
    } else {
        if (wb_cstr(&top, "")) { wb_free(&top); wb_free(&priv); return NULL; }
    }
    if (wb_u32(&top, 1) || wb_str(&top, pubblob, publen) || wb_str(&top, priv.d, priv.len)) {
        wb_free(&top); wb_free(&priv); return NULL;
    }
    wb_free(&priv);
    char *pem = openssh_pem_wrap(top.d, top.len);
    wb_free(&top);
    if (!pem) snprintf(err, errlen, "封装失败");
    return pem;
}

// ── 对外：生成 ──────────────────────────────────────────────────────────────
int termo_key_generate(int type, const char *comment, const char *passphrase,
                       char *out_priv, int priv_cap,
                       char *out_pub, int pub_cap,
                       char *out_fp, int fp_cap,
                       char *err, int errlen) {
    int is_ed = (type == 0);
    EVP_PKEY *pk = is_ed ? EVP_PKEY_Q_keygen(NULL, NULL, "ED25519")
                         : EVP_PKEY_Q_keygen(NULL, NULL, "RSA", (size_t)4096);
    if (!pk) { snprintf(err, (size_t)errlen, "生成密钥失败"); return -1; }

    unsigned char *blob = NULL; size_t bloblen = 0;
    if (pub_blob(pk, is_ed, &blob, &bloblen) != 0) { snprintf(err, (size_t)errlen, "导出公钥失败"); EVP_PKEY_free(pk); return -1; }
    publine_from_blob(blob, bloblen, is_ed ? "ssh-ed25519" : "ssh-rsa", comment, out_pub, pub_cap);
    fp_from_blob(blob, bloblen, out_fp, fp_cap);

    int rc = 0;
    if (is_ed) {
        unsigned char seed[32], pub[32]; size_t sl = sizeof(seed), pl = sizeof(pub);
        if (EVP_PKEY_get_raw_private_key(pk, seed, &sl) != 1 || sl != 32 ||
            EVP_PKEY_get_raw_public_key(pk, pub, &pl) != 1 || pl != 32) {
            snprintf(err, (size_t)errlen, "导出私钥失败"); rc = -1;
        } else {
            char *pem = build_openssh_ed25519(blob, bloblen, seed, pub, comment ? comment : "", passphrase, err, errlen);
            if (!pem) rc = -1;
            else { snprintf(out_priv, (size_t)priv_cap, "%s", pem); free(pem); }
        }
    } else {
        BIO *bio = BIO_new(BIO_s_mem());
        const EVP_CIPHER *cipher = (passphrase && *passphrase) ? EVP_aes_256_cbc() : NULL;
        int ok = bio && PEM_write_bio_PKCS8PrivateKey(bio, pk, cipher,
                        NULL, 0, NULL, (void *)(passphrase ? passphrase : ""));
        if (!ok) { snprintf(err, (size_t)errlen, "导出私钥失败"); rc = -1; }
        else {
            char *data = NULL; long n = BIO_get_mem_data(bio, &data);
            if (n <= 0 || n >= priv_cap) { snprintf(err, (size_t)errlen, "私钥缓冲不足"); rc = -1; }
            else { memcpy(out_priv, data, (size_t)n); out_priv[n] = '\0'; }
        }
        if (bio) BIO_free(bio);
    }
    free(blob);
    EVP_PKEY_free(pk);
    return rc;
}

// ── 对外：从私钥派生公钥（导入用）──────────────────────────────────────────
// 返回 0=派生成功(out_pub 写无注释公钥行、*out_type 0/1、*out_encrypted 0/1)；1=私钥已加密无法派生；-1=错误。
// 注：OpenSSH 格式的公钥在容器里是明文，即使加密也能派生（rc=0 且 *out_encrypted=1）。
int termo_key_pubkey_from_private(const char *priv_path, const char *passphrase,
                                  char *out_pub, int pub_cap, int *out_type, int *out_encrypted) {
    if (out_encrypted) *out_encrypted = 0;
    FILE *fp = fopen(priv_path, "rb");
    if (!fp) return -1;
    // 读全文件判断是否 OpenSSH 格式
    fseek(fp, 0, SEEK_END); long fsz = ftell(fp); fseek(fp, 0, SEEK_SET);
    if (fsz <= 0 || fsz > 1024 * 1024) { fclose(fp); return -1; }
    char *txt = malloc((size_t)fsz + 1);
    if (!txt) { fclose(fp); return -1; }
    size_t rd = fread(txt, 1, (size_t)fsz, fp); txt[rd] = '\0';

    int result = -1;
    if (strstr(txt, "BEGIN OPENSSH PRIVATE KEY")) {
        // 公钥在容器里是明文，无需解密即可取
        const char *b = strstr(txt, "-----BEGIN OPENSSH PRIVATE KEY-----");
        const char *e = strstr(txt, "-----END OPENSSH PRIVATE KEY-----");
        if (b && e) {
            b += strlen("-----BEGIN OPENSSH PRIVATE KEY-----");
            size_t blen = (size_t)(e - b);
            unsigned char *bin = malloc(blen);
            if (bin) {
                int n = kb64_decode_seg(b, blen, bin, blen);
                if (n > 0) {
                    // 解析容器到 publickey blob（公钥明文，即使加密也能取）
                    result = parse_openssh_pub(bin, (size_t)n, out_pub, pub_cap, out_type, out_encrypted);
                }
                free(bin);
            }
        }
    } else {
        // PEM（RSA/EC）：用 OpenSSL 读私钥并派生公钥
        BIO *bio = BIO_new_mem_buf(txt, (int)rd);
        EVP_PKEY *pk = bio ? PEM_read_bio_PrivateKey(bio, NULL, NULL,
                              (void *)(passphrase ? passphrase : "")) : NULL;
        if (bio) BIO_free(bio);
        if (pk) {
            int is_ed = EVP_PKEY_id(pk) == EVP_PKEY_ED25519;
            unsigned char *blob = NULL; size_t bloblen = 0;
            if (pub_blob(pk, is_ed, &blob, &bloblen) == 0) {
                publine_from_blob(blob, bloblen, is_ed ? "ssh-ed25519" : "ssh-rsa", NULL, out_pub, pub_cap);
                if (out_type) *out_type = is_ed ? 0 : 1;
                free(blob);
                result = 0;
            }
            EVP_PKEY_free(pk);
        } else {
            // 读失败：多半是加密（口令不对/未给）→ 报「已加密」
            if (strstr(txt, "ENCRYPTED")) result = 1;
        }
    }
    free(txt);
    fclose(fp);
    return result;
}

// 解析 openssh-key-v1 二进制，取出第一把公钥 blob → 公钥行 + 类型 + 是否加密。返回 0/-1。
static int parse_openssh_pub(const unsigned char *p, size_t len, char *out_pub, int pub_cap,
                             int *out_type, int *out_encrypted) {
    size_t o = 0;
    #define RD_U32(v) do { if (o + 4 > len) return -1; (v) = ((unsigned)p[o]<<24)|((unsigned)p[o+1]<<16)|((unsigned)p[o+2]<<8)|p[o+3]; o += 4; } while(0)
    #define SKIP_STR() do { unsigned _l; RD_U32(_l); if (o + _l > len) return -1; o += _l; } while(0)
    static const char magic[] = "openssh-key-v1";
    if (len < sizeof(magic) || memcmp(p, magic, sizeof(magic)) != 0) return -1;
    o = sizeof(magic);             // 跳过 magic + \0
    unsigned cl; RD_U32(cl);       // ciphername
    if (o + cl > len) return -1;
    if (out_encrypted) *out_encrypted = !(cl == 4 && memcmp(p + o, "none", 4) == 0);
    o += cl;
    SKIP_STR();                    // kdfname
    SKIP_STR();                    // kdfoptions
    unsigned nkeys; RD_U32(nkeys);
    if (nkeys < 1) return -1;
    unsigned bloblen; RD_U32(bloblen);
    if (o + bloblen > len) return -1;
    const unsigned char *blob = p + o;
    // blob 内首字段是类型名
    if (bloblen < 4) return -1;
    unsigned tl = ((unsigned)blob[0]<<24)|((unsigned)blob[1]<<16)|((unsigned)blob[2]<<8)|blob[3];
    const char *type = "ssh-ed25519"; int t = 0;
    if (tl == 7 && bloblen >= 11 && memcmp(blob+4, "ssh-rsa", 7) == 0) { type = "ssh-rsa"; t = 1; }
    publine_from_blob(blob, bloblen, type, NULL, out_pub, pub_cap);
    if (out_type) *out_type = t;
    return 0;
    #undef RD_U32
    #undef SKIP_STR
}

// base64 解码一段（带长度，非 NUL 结尾）。
static int kb64_decode_seg(const char *src, size_t srclen, unsigned char *out, size_t out_cap) {
    int tbl[256]; for (int i = 0; i < 256; i++) tbl[i] = -1;
    for (int i = 0; i < 64; i++) tbl[(unsigned char)KB64[i]] = i;
    unsigned acc = 0; int bits = 0; size_t o = 0;
    for (size_t i = 0; i < srclen; i++) {
        char ch = src[i];
        if (ch == '=' || ch == '\n' || ch == '\r' || ch == ' ' || ch == '\t') continue;
        int v = tbl[(unsigned char)ch];
        if (v < 0) continue;
        acc = (acc << 6) | (unsigned)v; bits += 6;
        if (bits >= 8) { bits -= 8; if (o >= out_cap) return -1; out[o++] = (unsigned char)((acc >> bits) & 0xFF); }
    }
    return (int)o;
}

// 由公钥行算指纹 "SHA256:..."。返回 0/-1。
int termo_key_fingerprint(const char *pub_line, char *out_fp, int fp_cap) {
    // 取第 2 字段（base64 blob）
    const char *s = pub_line;
    while (*s == ' ') s++;
    const char *sp = strchr(s, ' ');
    if (!sp) return -1;
    const char *b = sp + 1;
    const char *be = strchr(b, ' ');
    size_t blen = be ? (size_t)(be - b) : strlen(b);
    unsigned char *bin = malloc(blen);
    if (!bin) return -1;
    int n = kb64_decode_seg(b, blen, bin, blen);
    if (n <= 0) { free(bin); return -1; }
    fp_from_blob(bin, (size_t)n, out_fp, fp_cap);
    free(bin);
    return 0;
}
