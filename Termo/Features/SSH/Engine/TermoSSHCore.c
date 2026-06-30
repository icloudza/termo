//  libssh2 进程内 SSH 引擎 C 实现：连接/认证/主机密钥校验、exec（含 stdin/超时/流式/上传）、
//  交互式 shell（终端 PTY）、SFTP（libssh2_sftp_*）、端口转发（-L/-R/-D 多路复用）、分阶段测试连接。
//  替代原先全套 spawn /usr/bin/ssh。
#include "TermoSSHCore.h"

#include <libssh2.h>
#include <libssh2_sftp.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <netdb.h>
#include <netinet/in.h>
#include <time.h>
#include <pthread.h>

// ── 小工具 ──────────────────────────────────────────────────────────────────
static const char B64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

// 标准 base64，不补 '='（OpenSSH 指纹风格）。dst 需 ≥ ((len+2)/3)*4 + 1。
static void b64_nopad(const unsigned char *src, size_t len, char *dst) {
    size_t i = 0, o = 0;
    while (i + 3 <= len) {
        unsigned v = (src[i] << 16) | (src[i + 1] << 8) | src[i + 2];
        dst[o++] = B64[(v >> 18) & 63]; dst[o++] = B64[(v >> 12) & 63];
        dst[o++] = B64[(v >> 6) & 63];  dst[o++] = B64[v & 63];
        i += 3;
    }
    if (len - i == 1) {
        unsigned v = src[i] << 16;
        dst[o++] = B64[(v >> 18) & 63]; dst[o++] = B64[(v >> 12) & 63];
    } else if (len - i == 2) {
        unsigned v = (src[i] << 16) | (src[i + 1] << 8);
        dst[o++] = B64[(v >> 18) & 63]; dst[o++] = B64[(v >> 12) & 63];
        dst[o++] = B64[(v >> 6) & 63];
    }
    dst[o] = '\0';
}

// 标准 base64（补 '='，known_hosts 行用）。dst 需 ≥ ((len+2)/3)*4 + 1。
static void b64_pad(const unsigned char *src, size_t len, char *dst, size_t dstcap) {
    size_t need = ((len + 2) / 3) * 4;
    if (dstcap < need + 1) { if (dstcap) dst[0] = '\0'; return; }
    size_t i = 0, o = 0;
    while (i + 3 <= len) {
        unsigned v = (src[i] << 16) | (src[i + 1] << 8) | src[i + 2];
        dst[o++] = B64[(v >> 18) & 63]; dst[o++] = B64[(v >> 12) & 63];
        dst[o++] = B64[(v >> 6) & 63];  dst[o++] = B64[v & 63];
        i += 3;
    }
    size_t rem = len - i;
    if (rem == 1) {
        unsigned v = src[i] << 16;
        dst[o++] = B64[(v >> 18) & 63]; dst[o++] = B64[(v >> 12) & 63];
        dst[o++] = '='; dst[o++] = '=';
    } else if (rem == 2) {
        unsigned v = (src[i] << 16) | (src[i + 1] << 8);
        dst[o++] = B64[(v >> 18) & 63]; dst[o++] = B64[(v >> 12) & 63];
        dst[o++] = B64[(v >> 6) & 63];  dst[o++] = '=';
    }
    dst[o] = '\0';
}

// 握手后从会话取主机指纹，写入 sha（"SHA256:base64"）与 md5（"ab:cd:…"）缓冲。
static void fill_fingerprints(LIBSSH2_SESSION *session, char *sha, size_t shacap, char *md5, size_t md5cap) {
    if (sha && shacap) {
        const char *h = libssh2_hostkey_hash(session, LIBSSH2_HOSTKEY_HASH_SHA256);
        if (h) { char b64[64]; b64_nopad((const unsigned char *)h, 32, b64); snprintf(sha, shacap, "SHA256:%s", b64); }
        else sha[0] = '\0';
    }
    if (md5 && md5cap) {
        const char *h = libssh2_hostkey_hash(session, LIBSSH2_HOSTKEY_HASH_MD5);
        if (h) { char *p = md5; for (int i = 0; i < 16; i++) p += snprintf(p, 4, i ? ":%02x" : "%02x", (unsigned char)h[i]); }
        else md5[0] = '\0';
    }
}

static const char *hostkey_typename(int keytype) {
    switch (keytype) {
        case LIBSSH2_HOSTKEY_TYPE_RSA:       return "ssh-rsa";
        case LIBSSH2_HOSTKEY_TYPE_DSS:       return "ssh-dss";
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_256: return "ecdsa-sha2-nistp256";
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_384: return "ecdsa-sha2-nistp384";
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_521: return "ecdsa-sha2-nistp521";
        case LIBSSH2_HOSTKEY_TYPE_ED25519:   return "ssh-ed25519";
        default: return NULL;
    }
}

// 对照 known_hosts 校验当前会话的主机密钥。返回 0=匹配 1=未知 2=不匹配。
// line_out 非空时产出标准 known_hosts 行（供信任写入）。保守：取不到密钥/解析失败按「未知」(1)，绝不误报不匹配。
static int hostkey_check(LIBSSH2_SESSION *session, const char *host, int port,
                         const char *real_file, const char *session_file,
                         char *line_out, size_t line_cap) {
    if (line_out && line_cap) line_out[0] = '\0';
    size_t keylen = 0; int keytype = 0;
    const char *key = libssh2_session_hostkey(session, &keylen, &keytype);
    if (!key) return 1;

    if (line_out && line_cap) {
        const char *tn = hostkey_typename(keytype);
        if (tn) {
            char spec[300];
            if (port == 22) snprintf(spec, sizeof(spec), "%s", host);
            else snprintf(spec, sizeof(spec), "[%s]:%d", host, port);
            size_t cap = ((keylen + 2) / 3) * 4 + 1;
            char *b64 = malloc(cap);
            if (b64) { b64_pad((const unsigned char *)key, keylen, b64, cap);
                       snprintf(line_out, line_cap, "%s %s %s", spec, tn, b64); free(b64); }
        }
    }

    LIBSSH2_KNOWNHOSTS *nh = libssh2_knownhost_init(session);
    if (!nh) return 1;
    if (real_file && *real_file)    libssh2_knownhost_readfile(nh, real_file, LIBSSH2_KNOWNHOST_FILE_OPENSSH);
    if (session_file && *session_file) libssh2_knownhost_readfile(nh, session_file, LIBSSH2_KNOWNHOST_FILE_OPENSSH);
    struct libssh2_knownhost *kh = NULL;
    int check = libssh2_knownhost_checkp(nh, host, port, key, keylen,
                                         LIBSSH2_KNOWNHOST_TYPE_PLAIN | LIBSSH2_KNOWNHOST_KEYENC_RAW, &kh);
    libssh2_knownhost_free(nh);
    if (check == LIBSSH2_KNOWNHOST_CHECK_MATCH)    return 0;
    if (check == LIBSSH2_KNOWNHOST_CHECK_MISMATCH) return 2;
    return 1;   // NOTFOUND / FAILURE → 未知，放行
}

// 非阻塞 connect + select 超时（秒）。成功返回已连接的阻塞 socket fd，失败返回 -1。
static int tcp_connect(const char *host, int port, int timeout_sec, char *err, size_t errlen) {
    char portstr[16];
    snprintf(portstr, sizeof(portstr), "%d", port);
    struct addrinfo hints, *res = NULL, *ai;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    int gai = getaddrinfo(host, portstr, &hints, &res);
    if (gai != 0) {
        snprintf(err, errlen, "解析主机失败：%s", gai_strerror(gai));
        return -1;
    }
    int sock = -1;
    for (ai = res; ai; ai = ai->ai_next) {
        sock = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (sock < 0) continue;
        int flags = fcntl(sock, F_GETFL, 0);
        fcntl(sock, F_SETFL, flags | O_NONBLOCK);
        int rc = connect(sock, ai->ai_addr, ai->ai_addrlen);
        if (rc == 0) { fcntl(sock, F_SETFL, flags); break; }   // 立即连上
        if (errno == EINPROGRESS) {
            fd_set wf; FD_ZERO(&wf); FD_SET(sock, &wf);
            struct timeval tv = { timeout_sec, 0 };
            rc = select(sock + 1, NULL, &wf, NULL, &tv);
            if (rc > 0) {
                int soerr = 0; socklen_t l = sizeof(soerr);
                getsockopt(sock, SOL_SOCKET, SO_ERROR, &soerr, &l);
                if (soerr == 0) { fcntl(sock, F_SETFL, flags); break; }  // 连上
            }
        }
        close(sock); sock = -1;   // 本地址失败，试下一个
    }
    freeaddrinfo(res);
    if (sock < 0) snprintf(err, errlen, "连接 %s:%d 失败或超时", host, port);
    return sock;
}

// ── 持久会话 ────────────────────────────────────────────────────────────────
struct TermoSSHSession {
    int sock;
    LIBSSH2_SESSION *session;
    char fp_sha256[80];
    char fp_md5[64];
    volatile int cancel;   // 流式读取的中止标志（另一线程置位）
};

TermoSSHSession *termo_ssh_open(const char *host, int port,
                                const char *user, const char *password,
                                const char *key_path, const char *key_passphrase,
                                const char *real_known_hosts, const char *session_known_hosts,
                                char *err, int errlen) {
    libssh2_init(0);   // 引用计数，安全重复调用
    int sock = tcp_connect(host ? host : "", port, 10, err, (size_t)errlen);
    if (sock < 0) return NULL;

    LIBSSH2_SESSION *session = libssh2_session_init();
    if (!session) {
        snprintf(err, (size_t)errlen, "libssh2_session_init 失败");
        close(sock);
        return NULL;
    }
    libssh2_session_set_blocking(session, 1);
    libssh2_session_set_timeout(session, 15000);

    int rc = libssh2_session_handshake(session, sock);
    if (rc) {
        char *msg = NULL; libssh2_session_last_error(session, &msg, NULL, 0);
        snprintf(err, (size_t)errlen, "握手失败 (%d)：%s", rc, msg ? msg : "");
        goto fail;
    }

    // 认证前校验主机密钥：仅明确不匹配（疑似 MITM）才拒，绝不把密码送给冒名服务器。
    if ((real_known_hosts && *real_known_hosts) || (session_known_hosts && *session_known_hosts)) {
        if (hostkey_check(session, host ? host : "", port,
                          real_known_hosts, session_known_hosts, NULL, 0) == 2) {
            snprintf(err, (size_t)errlen, "HOSTKEY_MISMATCH 主机密钥与已知记录不匹配（疑似中间人攻击），已拒绝连接");
            goto fail;
        }
    }

    if (key_path && *key_path) {
        rc = libssh2_userauth_publickey_fromfile(session, user ? user : "", NULL,
                                                 key_path, key_passphrase ? key_passphrase : "");
    } else {
        rc = libssh2_userauth_password(session, user ? user : "", password ? password : "");
    }
    if (rc) {
        char *msg = NULL; libssh2_session_last_error(session, &msg, NULL, 0);
        snprintf(err, (size_t)errlen, "认证失败 (%d)：%s", rc, msg ? msg : "");
        goto fail;
    }

    TermoSSHSession *s = calloc(1, sizeof(*s));
    if (!s) { snprintf(err, (size_t)errlen, "分配失败"); goto fail; }
    s->sock = sock;
    s->session = session;
    const char *sha = libssh2_hostkey_hash(session, LIBSSH2_HOSTKEY_HASH_SHA256);
    if (sha) {
        char b64[64];
        b64_nopad((const unsigned char *)sha, 32, b64);
        snprintf(s->fp_sha256, sizeof(s->fp_sha256), "SHA256:%s", b64);
    }
    const char *md5 = libssh2_hostkey_hash(session, LIBSSH2_HOSTKEY_HASH_MD5);
    if (md5) {
        char *p = s->fp_md5;
        for (int i = 0; i < 16; i++)
            p += snprintf(p, 4, i ? ":%02x" : "%02x", (unsigned char)md5[i]);
    }
    return s;

fail:
    libssh2_session_disconnect(session, "open failed");
    libssh2_session_free(session);
    close(sock);
    return NULL;
}

const char *termo_ssh_session_sha256(TermoSSHSession *s) { return s ? s->fp_sha256 : ""; }
const char *termo_ssh_session_md5(TermoSSHSession *s) { return s ? s->fp_md5 : ""; }

void termo_ssh_test(const char *host, int port, const char *user,
                    const char *password, const char *key_path, const char *key_passphrase,
                    TermoSSHStageCallback on_stage, void *ud) {
    if (!on_stage) return;
    #define STAGE(n, ok, msg) on_stage(ud, (n), (ok), (msg))
    libssh2_init(0);

    // 1. 解析主机地址
    char portstr[16]; snprintf(portstr, sizeof(portstr), "%d", port);
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM;
    int gai = getaddrinfo(host ? host : "", portstr, &hints, &res);
    if (gai != 0 || !res) {
        char m[160]; snprintf(m, sizeof(m), "解析主机失败：%s", gai_strerror(gai));
        STAGE(1, 0, m); return;
    }
    STAGE(1, 1, NULL);

    // 2. 建立 TCP 连接（逐地址尝试，非阻塞 connect + select 超时）
    int sock = -1;
    for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
        sock = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (sock < 0) continue;
        int flags = fcntl(sock, F_GETFL, 0);
        fcntl(sock, F_SETFL, flags | O_NONBLOCK);
        int rc = connect(sock, ai->ai_addr, ai->ai_addrlen);
        if (rc == 0) { fcntl(sock, F_SETFL, flags); break; }
        if (errno == EINPROGRESS) {
            fd_set wf; FD_ZERO(&wf); FD_SET(sock, &wf);
            struct timeval tv = { 10, 0 };
            if (select(sock + 1, NULL, &wf, NULL, &tv) > 0) {
                int soerr = 0; socklen_t l = sizeof(soerr);
                getsockopt(sock, SOL_SOCKET, SO_ERROR, &soerr, &l);
                if (soerr == 0) { fcntl(sock, F_SETFL, flags); break; }
            }
        }
        close(sock); sock = -1;
    }
    freeaddrinfo(res);
    if (sock < 0) { STAGE(2, 0, "无法建立 TCP 连接（端口不通、被拒或被本地网络权限拦截）"); return; }
    STAGE(2, 1, NULL);

    // 3. SSH 协议握手
    LIBSSH2_SESSION *session = libssh2_session_init();
    if (!session) { STAGE(3, 0, "libssh2 初始化失败"); close(sock); return; }
    libssh2_session_set_blocking(session, 1);
    libssh2_session_set_timeout(session, 15000);
    int rc = libssh2_session_handshake(session, sock);
    if (rc) {
        char *e = NULL; libssh2_session_last_error(session, &e, NULL, 0);
        char m[220]; snprintf(m, sizeof(m), "SSH 握手失败 (%d)：%s", rc, e ? e : "");
        STAGE(3, 0, m);
        libssh2_session_free(session); close(sock); return;
    }
    STAGE(3, 1, NULL);

    // 4. 身份验证
    if (key_path && *key_path)
        rc = libssh2_userauth_publickey_fromfile(session, user ? user : "", NULL,
                                                 key_path, key_passphrase ? key_passphrase : "");
    else
        rc = libssh2_userauth_password(session, user ? user : "", password ? password : "");
    if (rc) {
        char *e = NULL; libssh2_session_last_error(session, &e, NULL, 0);
        char m[220]; snprintf(m, sizeof(m), "身份验证失败 (%d)：%s", rc, e ? e : "");
        STAGE(4, 0, m);
        libssh2_session_disconnect(session, "auth failed"); libssh2_session_free(session); close(sock); return;
    }
    STAGE(4, 1, NULL);

    // 5. 完成
    STAGE(5, 1, NULL);
    libssh2_session_disconnect(session, "test done");
    libssh2_session_free(session);
    close(sock);
    #undef STAGE
}

void termo_ssh_scan_hostkey(const char *host, int port,
                            const char *real_known_hosts, const char *session_known_hosts,
                            TermoHostKeyScan *out) {
    if (!out) return;
    memset(out, 0, sizeof(*out));
    out->status = -1;
    libssh2_init(0);
    char errbuf[128];
    int sock = tcp_connect(host ? host : "", port, 8, errbuf, sizeof(errbuf));
    if (sock < 0) return;
    LIBSSH2_SESSION *session = libssh2_session_init();
    if (!session) { close(sock); return; }
    libssh2_session_set_blocking(session, 1);
    libssh2_session_set_timeout(session, 8000);
    if (libssh2_session_handshake(session, sock) == 0) {     // 仅握手，不认证
        fill_fingerprints(session, out->sha256, sizeof(out->sha256), out->md5, sizeof(out->md5));
        out->status = hostkey_check(session, host ? host : "", port,
                                    real_known_hosts, session_known_hosts,
                                    out->line, sizeof(out->line));
    }
    libssh2_session_disconnect(session, "scan done");
    libssh2_session_free(session);
    close(sock);
}

// 把通道某条流读到缓冲（stream_id：0=stdout、SSH_EXTENDED_DATA_STDERR=stderr），截断到 cap-1。
static void drain_stream(LIBSSH2_CHANNEL *ch, int stream_id, char *buf, int cap) {
    if (!buf || cap <= 0) return;
    size_t off = 0;
    for (;;) {
        ssize_t n = libssh2_channel_read_ex(ch, stream_id, buf + off, (size_t)cap - 1 - off);
        if (n > 0) { off += (size_t)n; if (off >= (size_t)cap - 1) break; }
        else break;   // 0=EOF，<0=错误（阻塞模式无 EAGAIN）
    }
    buf[off] = '\0';
}

int termo_ssh_exec(TermoSSHSession *s, const char *command,
                   char *out, int out_cap, char *errout, int errout_cap,
                   int *exit_code, char *err, int errlen) {
    if (!s || !s->session) { snprintf(err, (size_t)errlen, "会话无效"); return -1; }
    LIBSSH2_CHANNEL *ch = libssh2_channel_open_session(s->session);
    if (!ch) {
        char *msg = NULL; libssh2_session_last_error(s->session, &msg, NULL, 0);
        snprintf(err, (size_t)errlen, "打开通道失败：%s", msg ? msg : "");
        return -1;
    }
    if (libssh2_channel_exec(ch, command ? command : "") != 0) {
        char *msg = NULL; libssh2_session_last_error(s->session, &msg, NULL, 0);
        snprintf(err, (size_t)errlen, "exec 失败：%s", msg ? msg : "");
        libssh2_channel_free(ch);
        return -1;
    }
    drain_stream(ch, 0, out, out_cap);                          // stdout
    drain_stream(ch, SSH_EXTENDED_DATA_STDERR, errout, errout_cap);  // stderr
    libssh2_channel_close(ch);
    if (exit_code) *exit_code = libssh2_channel_get_exit_status(ch);
    libssh2_channel_free(ch);
    return 0;
}

static long termo_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

int termo_ssh_exec2(TermoSSHSession *s, const char *command,
                    const char *stdin_bytes, int stdin_len,
                    char *out, int out_cap, int *out_len,
                    char *errout, int errout_cap, int *err_len,
                    int *exit_code, int timeout_ms, char *err, int errlen) {
    if (out_len) *out_len = 0;
    if (err_len) *err_len = 0;
    if (!s || !s->session) { snprintf(err, (size_t)errlen, "会话无效"); return -1; }
    if (s->cancel) return 2;                       // 借出前已被取消
    if (timeout_ms <= 0) timeout_ms = 20000;

    LIBSSH2_CHANNEL *ch = libssh2_channel_open_session(s->session);
    if (!ch) {
        char *msg = NULL; libssh2_session_last_error(s->session, &msg, NULL, 0);
        snprintf(err, (size_t)errlen, "打开通道失败：%s", msg ? msg : "");
        return -1;
    }
    if (libssh2_channel_exec(ch, command ? command : "") != 0) {
        char *msg = NULL; libssh2_session_last_error(s->session, &msg, NULL, 0);
        snprintf(err, (size_t)errlen, "exec 失败：%s", msg ? msg : "");
        libssh2_channel_free(ch);
        return -1;
    }

    libssh2_session_set_timeout(s->session, 200);   // 200ms 轮询：让阻塞调用周期返回以查 deadline/cancel
    long deadline = termo_now_ms() + timeout_ms;
    int result = 0;                                 // 0=完成 1=超时 2=取消 -1=错误

    // 写 stdin（若有）：写完即 send_eof。喂 stdin 的命令通常少 stdout（写文件类），先写后读不致双向死锁。
    if (stdin_bytes && stdin_len > 0) {
        size_t woff = 0;
        while (woff < (size_t)stdin_len) {
            if (s->cancel) { result = 2; break; }
            if (termo_now_ms() > deadline) { result = 1; break; }
            ssize_t w = libssh2_channel_write(ch, stdin_bytes + woff, (size_t)stdin_len - woff);
            if (w > 0) woff += (size_t)w;
            else if (w == LIBSSH2_ERROR_TIMEOUT || w == LIBSSH2_ERROR_EAGAIN) continue;
            else { snprintf(err, (size_t)errlen, "写 stdin 失败 (%ld)", (long)w); result = -1; break; }
        }
    }
    if (result == 0) libssh2_channel_send_eof(ch);

    // 读 stdout/stderr 直到 EOF / 超时 / 取消。输出超 cap 只截断、仍继续抽干，避免远端写阻塞导致永不 EOF。
    char tmp[8192];
    size_t ooff = 0, eoff = 0;
    while (result == 0) {
        if (s->cancel) { result = 2; break; }
        if (termo_now_ms() > deadline) { result = 1; break; }
        int got = 0;
        ssize_t n = libssh2_channel_read_ex(ch, 0, tmp, sizeof(tmp));
        if (n > 0) {
            got = 1;
            if (out && ooff < (size_t)out_cap) {
                size_t cp = (size_t)n; if (cp > (size_t)out_cap - ooff) cp = (size_t)out_cap - ooff;
                memcpy(out + ooff, tmp, cp); ooff += cp;
            }
        } else if (n < 0 && n != LIBSSH2_ERROR_TIMEOUT) {
            snprintf(err, (size_t)errlen, "读取错误 (%ld)", (long)n); result = -1; break;
        }
        ssize_t m = libssh2_channel_read_ex(ch, SSH_EXTENDED_DATA_STDERR, tmp, sizeof(tmp));
        if (m > 0) {
            got = 1;
            if (errout && eoff < (size_t)errout_cap) {
                size_t cp = (size_t)m; if (cp > (size_t)errout_cap - eoff) cp = (size_t)errout_cap - eoff;
                memcpy(errout + eoff, tmp, cp); eoff += cp;
            }
        }
        if (!got && libssh2_channel_eof(ch)) break;   // 无新数据且远端已 EOF → 完成
    }

    if (out_len) *out_len = (int)ooff;
    if (err_len) *err_len = (int)eoff;
    libssh2_session_set_timeout(s->session, 15000);
    libssh2_channel_close(ch);
    if (exit_code) *exit_code = libssh2_channel_get_exit_status(ch);
    libssh2_channel_free(ch);
    return result;
}

int termo_ssh_exec_upload(TermoSSHSession *s, const char *command,
                          TermoSSHPullCallback pull, void *ud,
                          int *exit_code, char *err, int errlen) {
    if (!s || !s->session) { snprintf(err, (size_t)errlen, "会话无效"); return -1; }
    LIBSSH2_CHANNEL *ch = libssh2_channel_open_session(s->session);
    if (!ch) {
        char *msg = NULL; libssh2_session_last_error(s->session, &msg, NULL, 0);
        snprintf(err, (size_t)errlen, "打开通道失败：%s", msg ? msg : "");
        return -1;
    }
    if (libssh2_channel_exec(ch, command ? command : "") != 0) {
        char *msg = NULL; libssh2_session_last_error(s->session, &msg, NULL, 0);
        snprintf(err, (size_t)errlen, "exec 失败：%s", msg ? msg : "");
        libssh2_channel_free(ch);
        return -1;
    }

    char buf[65536];
    int result = 0;                          // 0 完成 / 1 被取消 / -1 错误
    for (;;) {
        int n = pull ? pull(ud, buf, (int)sizeof(buf)) : 0;
        if (n < 0) { result = 1; break; }    // 取消/暂停：不 send_eof，远端 .part 留半截供续传
        if (n == 0) { libssh2_channel_send_eof(ch); break; }
        size_t off = 0;
        while (off < (size_t)n) {
            ssize_t w = libssh2_channel_write(ch, buf + off, (size_t)n - off);
            if (w > 0) off += (size_t)w;
            else if (w == LIBSSH2_ERROR_TIMEOUT || w == LIBSSH2_ERROR_EAGAIN) continue;
            else { snprintf(err, (size_t)errlen, "写入失败 (%ld)", (long)w); result = -1; break; }
        }
        if (result == -1) break;
    }
    if (result == 0) {                       // 排空远端的少量输出（cat 基本无输出）
        char tmp[4096];
        while (libssh2_channel_read(ch, tmp, sizeof(tmp)) > 0) {}
    }
    libssh2_channel_close(ch);
    if (exit_code) *exit_code = libssh2_channel_get_exit_status(ch);
    libssh2_channel_free(ch);
    return result;
}

int termo_ssh_exec_stream(TermoSSHSession *s, const char *command,
                          TermoSSHDataCallback on_data, void *userdata,
                          char *err, int errlen) {
    if (!s || !s->session) { snprintf(err, (size_t)errlen, "会话无效"); return -1; }
    // 不重置 s->cancel：会话单次流（用完即 close）。若被取代方已 cancel，这里须保持已取消、立即退出，
    // 否则会出现「孤儿流停不下来」竞态。cancel 初值由 open 时 calloc 置 0。
    if (s->cancel) return 0;
    LIBSSH2_CHANNEL *ch = libssh2_channel_open_session(s->session);
    if (!ch) {
        char *msg = NULL; libssh2_session_last_error(s->session, &msg, NULL, 0);
        snprintf(err, (size_t)errlen, "打开通道失败：%s", msg ? msg : "");
        return -1;
    }
    if (libssh2_channel_exec(ch, command ? command : "") != 0) {
        char *msg = NULL; libssh2_session_last_error(s->session, &msg, NULL, 0);
        snprintf(err, (size_t)errlen, "exec 失败：%s", msg ? msg : "");
        libssh2_channel_free(ch);
        return -1;
    }
    libssh2_session_set_timeout(s->session, 300);   // 300ms：让阻塞读周期性返回以检查 cancel
    char buf[8192];
    int rc = 0;
    while (!s->cancel) {
        ssize_t n = libssh2_channel_read(ch, buf, sizeof(buf));
        if (n > 0) { if (on_data) on_data(userdata, buf, (int)n); }
        else if (n == LIBSSH2_ERROR_TIMEOUT) { continue; }       // 无数据：循环检查 cancel
        else if (n == 0) { if (libssh2_channel_eof(ch)) break; } // EOF（远端进程退出）
        else { rc = -1; snprintf(err, (size_t)errlen, "读取错误 (%ld)", (long)n); break; }
    }
    libssh2_session_set_timeout(s->session, 15000);
    libssh2_channel_close(ch);
    libssh2_channel_free(ch);
    return rc;
}

void termo_ssh_cancel(TermoSSHSession *s) {
    if (s) s->cancel = 1;
}

void termo_ssh_close(TermoSSHSession *s) {
    if (!s) return;
    if (s->session) {
        libssh2_session_disconnect(s->session, "termo close");
        libssh2_session_free(s->session);
    }
    if (s->sock >= 0) close(s->sock);
    free(s);
}

// ── 交互式 shell（终端 PTY）─────────────────────────────────────────────────
struct TermoSSHShell {
    TermoSSHSession *s;
    LIBSSH2_CHANNEL *ch;
    pthread_t thread;
    int thread_started;
    pthread_mutex_t lock;
    char *wbuf; size_t wlen, wcap;        // 待写缓冲（main 入队、pump 排空）
    int wake[2];                          // 自管道：[0]读 [1]写，唤醒 pump 的 select
    volatile int cols, rows, resize_pending;
    volatile int stop;
    TermoSSHDataCallback on_data;
    TermoSSHClosedCallback on_closed;
    void *ud;
};

static void shell_wake(TermoSSHShell *sh) {
    char x = 'x';
    ssize_t r = write(sh->wake[1], &x, 1);   // 非阻塞；满了也无所谓（已有唤醒待处理）
    (void)r;
}

static void *shell_pump(void *arg) {
    TermoSSHShell *sh = (TermoSSHShell *)arg;
    LIBSSH2_SESSION *session = sh->s->session;
    int sock = sh->s->sock;
    libssh2_session_set_blocking(session, 0);
    char rbuf[16384];
    int errored = 0;

    while (!sh->stop) {
        int progressed = 0;

        if (sh->resize_pending) {
            sh->resize_pending = 0;
            libssh2_channel_request_pty_size(sh->ch, sh->cols, sh->rows);   // best-effort
        }

        ssize_t n = libssh2_channel_read(sh->ch, rbuf, sizeof(rbuf));
        if (n > 0) {
            if (sh->on_data) sh->on_data(sh->ud, rbuf, (int)n);
            progressed = 1;
        } else if (n == LIBSSH2_ERROR_EAGAIN) {
            // 暂无数据
        } else if (n == 0) {
            if (libssh2_channel_eof(sh->ch)) break;        // 远端 shell 退出（用户 exit）
        } else {
            errored = 1; break;                            // 连接错误（掉线）
        }

        pthread_mutex_lock(&sh->lock);
        while (sh->wlen > 0) {
            ssize_t w = libssh2_channel_write(sh->ch, sh->wbuf, sh->wlen);
            if (w > 0) {
                memmove(sh->wbuf, sh->wbuf + w, sh->wlen - (size_t)w);
                sh->wlen -= (size_t)w;
                progressed = 1;
            } else break;                                  // EAGAIN/错误：留到下轮
        }
        pthread_mutex_unlock(&sh->lock);

        if (progressed) continue;                          // 还有活，立即再来一轮

        // 无进展：select 等 socket 可读/写或被 wake 管道唤醒，避免忙等
        fd_set rfds, wfds;
        FD_ZERO(&rfds); FD_ZERO(&wfds);
        FD_SET(sock, &rfds);
        FD_SET(sh->wake[0], &rfds);
        if (libssh2_session_block_directions(session) & LIBSSH2_SESSION_BLOCK_OUTBOUND) FD_SET(sock, &wfds);
        int maxfd = sock > sh->wake[0] ? sock : sh->wake[0];
        struct timeval tv = { 0, 100000 };                 // 100ms 兜底
        select(maxfd + 1, &rfds, &wfds, NULL, &tv);
        if (FD_ISSET(sh->wake[0], &rfds)) {
            char drain[64];
            while (read(sh->wake[0], drain, sizeof(drain)) > 0) {}   // 排空（非阻塞）
        }
    }

    int exit_code = errored ? 255 : libssh2_channel_get_exit_status(sh->ch);
    if (sh->on_closed) sh->on_closed(sh->ud, exit_code);
    return NULL;
}

TermoSSHShell *termo_ssh_shell_open(TermoSSHSession *s, int cols, int rows,
                                    TermoSSHDataCallback on_data,
                                    TermoSSHClosedCallback on_closed, void *userdata,
                                    char *err, int errlen) {
    if (!s || !s->session) { snprintf(err, (size_t)errlen, "会话无效"); return NULL; }
    libssh2_session_set_blocking(s->session, 1);
    LIBSSH2_CHANNEL *ch = libssh2_channel_open_session(s->session);
    if (!ch) {
        char *msg = NULL; libssh2_session_last_error(s->session, &msg, NULL, 0);
        snprintf(err, (size_t)errlen, "打开通道失败：%s", msg ? msg : "");
        return NULL;
    }
    if (libssh2_channel_request_pty_ex(ch, "xterm-256color", 14, NULL, 0,
                                       cols > 0 ? cols : 80, rows > 0 ? rows : 24, 0, 0)) {
        snprintf(err, (size_t)errlen, "request pty 失败");
        libssh2_channel_free(ch); return NULL;
    }
    if (libssh2_channel_shell(ch)) {
        snprintf(err, (size_t)errlen, "启动 shell 失败");
        libssh2_channel_free(ch); return NULL;
    }
    TermoSSHShell *sh = calloc(1, sizeof(*sh));
    if (!sh) { snprintf(err, (size_t)errlen, "分配失败"); libssh2_channel_free(ch); return NULL; }
    sh->s = s; sh->ch = ch;
    sh->cols = cols; sh->rows = rows;
    sh->on_data = on_data; sh->on_closed = on_closed; sh->ud = userdata;
    pthread_mutex_init(&sh->lock, NULL);
    if (pipe(sh->wake) != 0) {
        snprintf(err, (size_t)errlen, "创建唤醒管道失败");
        pthread_mutex_destroy(&sh->lock); libssh2_channel_free(ch); free(sh); return NULL;
    }
    fcntl(sh->wake[0], F_SETFL, O_NONBLOCK);
    fcntl(sh->wake[1], F_SETFL, O_NONBLOCK);
    if (pthread_create(&sh->thread, NULL, shell_pump, sh) != 0) {
        snprintf(err, (size_t)errlen, "创建 pump 线程失败");
        close(sh->wake[0]); close(sh->wake[1]);
        pthread_mutex_destroy(&sh->lock); libssh2_channel_free(ch); free(sh); return NULL;
    }
    sh->thread_started = 1;
    return sh;
}

long termo_ssh_shell_write(TermoSSHShell *sh, const char *buf, int len) {
    if (!sh || !buf || len <= 0) return 0;
    pthread_mutex_lock(&sh->lock);
    if (sh->wlen + (size_t)len > sh->wcap) {
        size_t ncap = sh->wcap ? sh->wcap : 4096;
        while (ncap < sh->wlen + (size_t)len) ncap *= 2;
        char *nb = realloc(sh->wbuf, ncap);
        if (!nb) { pthread_mutex_unlock(&sh->lock); return -1; }
        sh->wbuf = nb; sh->wcap = ncap;
    }
    memcpy(sh->wbuf + sh->wlen, buf, (size_t)len);
    sh->wlen += (size_t)len;
    pthread_mutex_unlock(&sh->lock);
    shell_wake(sh);
    return len;
}

int termo_ssh_shell_resize(TermoSSHShell *sh, int cols, int rows) {
    if (!sh) return -1;
    sh->cols = cols; sh->rows = rows; sh->resize_pending = 1;
    shell_wake(sh);
    return 0;
}

void termo_ssh_shell_close(TermoSSHShell *sh) {
    if (!sh) return;
    sh->stop = 1;
    shell_wake(sh);
    if (sh->thread_started) pthread_join(sh->thread, NULL);
    if (sh->ch) {
        libssh2_session_set_blocking(sh->s->session, 1);
        libssh2_channel_close(sh->ch);
        libssh2_channel_free(sh->ch);
    }
    close(sh->wake[0]); close(sh->wake[1]);
    pthread_mutex_destroy(&sh->lock);
    free(sh->wbuf);
    free(sh);
}

// ── 端口转发（-L / -R / -D）──────────────────────────────────────────────────
#define FWD_MAX_CONN 128
#define FWD_BUF 16384

typedef struct {
    int in_use;
    int local_fd;
    LIBSSH2_CHANNEL *ch;
    char l2s[FWD_BUF]; size_t l2s_len;   // local→ssh 待写
    char s2l[FWD_BUF]; size_t s2l_len;   // ssh→local 待写
    int local_eof, ssh_eof, sent_eof;
} ForwardConn;

struct TermoSSHForward {
    TermoSSHSession *s;
    int kind;                            // 0 local 1 remote 2 dynamic
    char dest_host[256];
    int dest_port;
    int listen_fd;                       // -L/-D 本地监听；-R 为 -1
    LIBSSH2_LISTENER *rlistener;         // -R 远端监听
    pthread_t thread;
    int thread_started;
    int wake[2];
    volatile int stop;
    TermoSSHForwardStateCallback on_state;
    void *ud;
    ForwardConn conns[FWD_MAX_CONN];
};

static void fwd_wake(TermoSSHForward *f) { char x = 'x'; ssize_t r = write(f->wake[1], &x, 1); (void)r; }

static void set_nonblock(int fd) { int fl = fcntl(fd, F_GETFL, 0); fcntl(fd, F_SETFL, fl | O_NONBLOCK); }

// 建本地监听 socket；端口占用时 *eaddrinuse=1。失败返回 -1。
static int make_listen_socket(const char *bind_addr, int port, int *eaddrinuse) {
    *eaddrinuse = 0;
    char portstr[16]; snprintf(portstr, sizeof(portstr), "%d", port);
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM; hints.ai_flags = AI_PASSIVE;
    const char *node = (bind_addr && *bind_addr) ? bind_addr : NULL;
    if (getaddrinfo(node, portstr, &hints, &res) != 0 || !res) return -1;
    int fd = -1;
    for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
        int one = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        if (bind(fd, ai->ai_addr, ai->ai_addrlen) == 0 && listen(fd, 16) == 0) break;
        if (errno == EADDRINUSE) *eaddrinuse = 1;
        close(fd); fd = -1;
    }
    freeaddrinfo(res);
    return fd;
}

// 阻塞连接本地目标（-R 用）。失败返回 -1。
static int connect_blocking(const char *host, int port) {
    char portstr[16]; snprintf(portstr, sizeof(portstr), "%d", port);
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, portstr, &hints, &res) != 0 || !res) return -1;
    int fd = -1;
    for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
        if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) break;
        close(fd); fd = -1;
    }
    freeaddrinfo(res);
    return fd;
}

// 临时阻塞模式开 direct_tcpip channel（建立期短暂阻塞 pump，换取代码简洁）。
static LIBSSH2_CHANNEL *open_direct(LIBSSH2_SESSION *session, const char *host, int port) {
    libssh2_session_set_blocking(session, 1);
    libssh2_session_set_timeout(session, 8000);
    LIBSSH2_CHANNEL *ch = libssh2_channel_direct_tcpip_ex(session, host, port, "127.0.0.1", 0);
    libssh2_session_set_timeout(session, 0);
    libssh2_session_set_blocking(session, 0);
    return ch;
}

static int recv_n(int fd, unsigned char *buf, size_t n) {
    size_t off = 0;
    while (off < n) {
        ssize_t r = recv(fd, buf + off, n - off, 0);
        if (r > 0) off += (size_t)r;
        else if (r < 0 && errno == EINTR) continue;
        else return -1;
    }
    return 0;
}
static int send_all(int fd, const unsigned char *buf, size_t n) {
    size_t off = 0;
    while (off < n) {
        ssize_t w = send(fd, buf + off, n - off, 0);
        if (w > 0) off += (size_t)w;
        else if (w < 0 && errno == EINTR) continue;
        else return -1;
    }
    return 0;
}

// SOCKS5 协商（阻塞，带 recv 超时）。成功把目标写 dhost/dport 返回 0；失败返回 -1。
static int socks5_negotiate(int fd, char *dhost, size_t dhost_cap, int *dport) {
    struct timeval tv = { 10, 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    unsigned char b[300];
    if (recv_n(fd, b, 2) || b[0] != 0x05) return -1;       // VER NMETHODS
    int nm = b[1];
    if (nm > 0 && recv_n(fd, b, (size_t)nm)) return -1;     // 方法列表（忽略）
    unsigned char rep[2] = { 0x05, 0x00 };                  // 选无认证
    if (send_all(fd, rep, 2)) return -1;
    if (recv_n(fd, b, 4) || b[0] != 0x05 || b[1] != 0x01) return -1;   // VER CMD(CONNECT) RSV ATYP
    int atyp = b[3];
    if (atyp == 0x01) {
        unsigned char a[4]; if (recv_n(fd, a, 4)) return -1;
        snprintf(dhost, dhost_cap, "%d.%d.%d.%d", a[0], a[1], a[2], a[3]);
    } else if (atyp == 0x03) {
        unsigned char len; if (recv_n(fd, &len, 1)) return -1;
        if ((size_t)len >= dhost_cap) return -1;
        if (recv_n(fd, (unsigned char *)dhost, len)) return -1;
        dhost[len] = '\0';
    } else if (atyp == 0x04) {
        unsigned char a[16]; if (recv_n(fd, a, 16)) return -1;
        snprintf(dhost, dhost_cap, "%x:%x:%x:%x:%x:%x:%x:%x",
                 (a[0]<<8)|a[1], (a[2]<<8)|a[3], (a[4]<<8)|a[5], (a[6]<<8)|a[7],
                 (a[8]<<8)|a[9], (a[10]<<8)|a[11], (a[12]<<8)|a[13], (a[14]<<8)|a[15]);
    } else return -1;
    unsigned char pb[2]; if (recv_n(fd, pb, 2)) return -1;
    *dport = (pb[0] << 8) | pb[1];
    tv.tv_sec = 0; setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));   // 取消超时
    return 0;
}
static void socks5_reply(int fd, int rep) {
    unsigned char r[10] = { 0x05, (unsigned char)rep, 0x00, 0x01, 0,0,0,0, 0,0 };
    send_all(fd, r, sizeof(r));
}

static ForwardConn *fwd_alloc(TermoSSHForward *f) {
    for (int i = 0; i < FWD_MAX_CONN; i++) if (!f->conns[i].in_use) return &f->conns[i];
    return NULL;
}
static void conn_close(ForwardConn *c) {
    if (c->ch) { libssh2_channel_free(c->ch); }
    if (c->local_fd >= 0) close(c->local_fd);
    memset(c, 0, sizeof(*c));
}

// 接入一个已开好 channel 的连接（local_fd 设非阻塞）。失败则各自清理。
static void fwd_add(TermoSSHForward *f, int local_fd, LIBSSH2_CHANNEL *ch) {
    ForwardConn *c = fwd_alloc(f);
    if (!c) { close(local_fd); if (ch) libssh2_channel_free(ch); return; }
    set_nonblock(local_fd);
    c->in_use = 1; c->local_fd = local_fd; c->ch = ch;
}

// 单连接双向泵（非阻塞）。返回 -1 表示该连接应关闭。
static int conn_pump(ForwardConn *c) {
    // local → ssh
    if (!c->local_eof && c->l2s_len < FWD_BUF) {
        ssize_t n = recv(c->local_fd, c->l2s + c->l2s_len, FWD_BUF - c->l2s_len, 0);
        if (n > 0) c->l2s_len += (size_t)n;
        else if (n == 0) c->local_eof = 1;
        else if (errno != EAGAIN && errno != EWOULDBLOCK) c->local_eof = 1;
    }
    while (c->l2s_len > 0) {
        ssize_t w = libssh2_channel_write(c->ch, c->l2s, c->l2s_len);
        if (w > 0) { memmove(c->l2s, c->l2s + w, c->l2s_len - (size_t)w); c->l2s_len -= (size_t)w; }
        else break;                                  // EAGAIN/错误：下轮再试
    }
    if (c->local_eof && c->l2s_len == 0 && !c->sent_eof) { libssh2_channel_send_eof(c->ch); c->sent_eof = 1; }

    // ssh → local
    if (c->s2l_len < FWD_BUF) {
        ssize_t n = libssh2_channel_read(c->ch, c->s2l + c->s2l_len, FWD_BUF - c->s2l_len);
        if (n > 0) c->s2l_len += (size_t)n;
        else if (n == 0) c->ssh_eof = 1;             // EOF
        else if (n != LIBSSH2_ERROR_EAGAIN) c->ssh_eof = 1;
    }
    while (c->s2l_len > 0) {
        ssize_t w = send(c->local_fd, c->s2l, c->s2l_len, 0);
        if (w > 0) { memmove(c->s2l, c->s2l + w, c->s2l_len - (size_t)w); c->s2l_len -= (size_t)w; }
        else if (w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
        else { return -1; }                          // 本地写错误 → 关
    }
    // 任一侧 EOF 且其待发数据已 flush 完 → 关整条连接
    if ((c->ssh_eof && c->s2l_len == 0) || (c->local_eof && c->l2s_len == 0 && c->ssh_eof)) return -1;
    return 0;
}

static void *forward_pump(void *arg) {
    TermoSSHForward *f = (TermoSSHForward *)arg;
    LIBSSH2_SESSION *session = f->s->session;
    int sock = f->s->sock;
    libssh2_session_set_blocking(session, 0);
    libssh2_keepalive_config(session, 0, 30);
    int ticks = 0;
    int dead = 0;
    char deadmsg[128] = "连接已断开";

    while (!f->stop) {
        fd_set rfds, wfds;
        FD_ZERO(&rfds); FD_ZERO(&wfds);
        int maxfd = 0;
        FD_SET(f->wake[0], &rfds); if (f->wake[0] > maxfd) maxfd = f->wake[0];
        FD_SET(sock, &rfds);       if (sock > maxfd) maxfd = sock;
        if (f->listen_fd >= 0) { FD_SET(f->listen_fd, &rfds); if (f->listen_fd > maxfd) maxfd = f->listen_fd; }
        for (int i = 0; i < FWD_MAX_CONN; i++) {
            ForwardConn *c = &f->conns[i];
            if (!c->in_use) continue;
            if (!c->local_eof && c->l2s_len < FWD_BUF) { FD_SET(c->local_fd, &rfds); if (c->local_fd > maxfd) maxfd = c->local_fd; }
            if (c->s2l_len > 0) { FD_SET(c->local_fd, &wfds); if (c->local_fd > maxfd) maxfd = c->local_fd; }
        }
        struct timeval tv = { 0, 100000 };
        select(maxfd + 1, &rfds, &wfds, NULL, &tv);
        if (FD_ISSET(f->wake[0], &rfds)) { char d[64]; while (read(f->wake[0], d, sizeof(d)) > 0) {} }

        // -L/-D：接受新本地连接
        if (f->listen_fd >= 0 && FD_ISSET(f->listen_fd, &rfds)) {
            int cfd = accept(f->listen_fd, NULL, NULL);
            if (cfd >= 0) {
                if (f->kind == 2) {                  // 动态 SOCKS5
                    char dhost[256]; int dport = 0;
                    if (socks5_negotiate(cfd, dhost, sizeof(dhost), &dport) == 0) {
                        LIBSSH2_CHANNEL *ch = open_direct(session, dhost, dport);
                        if (ch) { socks5_reply(cfd, 0x00); fwd_add(f, cfd, ch); }
                        else { socks5_reply(cfd, 0x05); close(cfd); }   // 0x05=连接被拒
                    } else close(cfd);
                } else {                             // 本地 -L
                    LIBSSH2_CHANNEL *ch = open_direct(session, f->dest_host, f->dest_port);
                    if (ch) fwd_add(f, cfd, ch); else close(cfd);
                }
            }
        }

        // -R：接受服务器转回的连接，本地连 dest
        if (f->kind == 1 && f->rlistener) {
            for (;;) {
                LIBSSH2_CHANNEL *ch = libssh2_channel_forward_accept(f->rlistener);
                if (!ch) break;                       // 无更多（EAGAIN）
                int lfd = connect_blocking(f->dest_host, f->dest_port);
                if (lfd >= 0) fwd_add(f, lfd, ch); else libssh2_channel_free(ch);
            }
        }

        // 转发所有活动连接
        for (int i = 0; i < FWD_MAX_CONN; i++) {
            ForwardConn *c = &f->conns[i];
            if (!c->in_use) continue;
            if (conn_pump(c) < 0) conn_close(c);
        }

        // 周期 keepalive，借此探测会话是否已断
        if (++ticks >= 100) {                          // ~10s
            ticks = 0;
            int next = 0;
            int rc = libssh2_keepalive_send(session, &next);
            if (rc < 0 && rc != LIBSSH2_ERROR_EAGAIN) { dead = 1; break; }
        }
    }

    for (int i = 0; i < FWD_MAX_CONN; i++) if (f->conns[i].in_use) conn_close(&f->conns[i]);
    if (dead && f->on_state) f->on_state(f->ud, 0, deadmsg);
    return NULL;
}

TermoSSHForward *termo_ssh_forward_open(TermoSSHSession *s, int kind,
                                        const char *bind_addr, int listen_port,
                                        const char *dest_host, int dest_port,
                                        TermoSSHForwardStateCallback on_state, void *ud,
                                        char *err, int errlen) {
    if (!s || !s->session) { snprintf(err, (size_t)errlen, "会话无效"); return NULL; }
    TermoSSHForward *f = calloc(1, sizeof(*f));
    if (!f) { snprintf(err, (size_t)errlen, "分配失败"); return NULL; }
    f->s = s; f->kind = kind; f->listen_fd = -1;
    f->dest_port = dest_port;
    snprintf(f->dest_host, sizeof(f->dest_host), "%s", dest_host ? dest_host : "");
    f->on_state = on_state; f->ud = ud;

    if (kind == 1) {                                   // -R：远端监听
        libssh2_session_set_blocking(s->session, 1);
        int bound = 0;
        f->rlistener = libssh2_channel_forward_listen_ex(s->session,
                        (bind_addr && *bind_addr) ? (char *)bind_addr : NULL,
                        listen_port, &bound, 16);
        if (!f->rlistener) { snprintf(err, (size_t)errlen, "转发请求被拒绝"); free(f); return NULL; }
    } else {                                           // -L/-D：本地监听
        int eaddr = 0;
        f->listen_fd = make_listen_socket(bind_addr, listen_port, &eaddr);
        if (f->listen_fd < 0) {
            snprintf(err, (size_t)errlen, "%s", eaddr ? "本地端口已被占用" : "无法监听本地端口");
            free(f); return NULL;
        }
        set_nonblock(f->listen_fd);
    }

    if (pipe(f->wake) != 0) { snprintf(err, (size_t)errlen, "创建唤醒管道失败"); goto fail; }
    set_nonblock(f->wake[0]); set_nonblock(f->wake[1]);
    if (pthread_create(&f->thread, NULL, forward_pump, f) != 0) {
        snprintf(err, (size_t)errlen, "创建 pump 线程失败");
        close(f->wake[0]); close(f->wake[1]); goto fail;
    }
    f->thread_started = 1;
    return f;

fail:
    if (f->listen_fd >= 0) close(f->listen_fd);
    if (f->rlistener) { libssh2_session_set_blocking(s->session, 1); libssh2_channel_forward_cancel(f->rlistener); }
    free(f);
    return NULL;
}

void termo_ssh_forward_close(TermoSSHForward *f) {
    if (!f) return;
    f->stop = 1;
    fwd_wake(f);
    if (f->thread_started) pthread_join(f->thread, NULL);
    libssh2_session_set_blocking(f->s->session, 1);
    if (f->rlistener) libssh2_channel_forward_cancel(f->rlistener);
    if (f->listen_fd >= 0) close(f->listen_fd);
    close(f->wake[0]); close(f->wake[1]);
    free(f);
}

// ── SFTP 子系统（libssh2_sftp_*）─────────────────────────────────────────────

// libssh2 返回值 → 本端约定：0 成功 / >0 SFTP 状态码 / 0xF000 传输错误。
static int sftp_map(LIBSSH2_SFTP *sftp, int rc) {
    if (rc == 0) return 0;
    if (rc == LIBSSH2_ERROR_SFTP_PROTOCOL) return (int)libssh2_sftp_last_error(sftp);
    return 0xF000;
}

static void attrs_fill(TermoSFTPAttrs *out, const LIBSSH2_SFTP_ATTRIBUTES *a) {
    if (!out) return;
    out->has_size = (a->flags & LIBSSH2_SFTP_ATTR_SIZE) ? 1 : 0;
    out->has_perm = (a->flags & LIBSSH2_SFTP_ATTR_PERMISSIONS) ? 1 : 0;
    out->has_mtime = (a->flags & LIBSSH2_SFTP_ATTR_ACMODTIME) ? 1 : 0;
    out->size = (unsigned long long)a->filesize;
    out->permissions = (unsigned int)a->permissions;
    out->mtime = (unsigned int)a->mtime;
}

void *termo_sftp_init(TermoSSHSession *s) {
    if (!s || !s->session) return NULL;
    return libssh2_sftp_init(s->session);
}

void termo_sftp_shutdown(void *sftp) {
    if (sftp) libssh2_sftp_shutdown((LIBSSH2_SFTP *)sftp);
}

int termo_sftp_last_errno(void *sftp) {
    return sftp ? (int)libssh2_sftp_last_error((LIBSSH2_SFTP *)sftp) : 0;
}

int termo_sftp_stat(TermoSSHSession *s, void *sftp, const char *path, int follow, TermoSFTPAttrs *out) {
    if (!s || !sftp) return 0xF000;
    LIBSSH2_SFTP_ATTRIBUTES a;
    memset(&a, 0, sizeof(a));
    int rc = libssh2_sftp_stat_ex((LIBSSH2_SFTP *)sftp, path, (unsigned)strlen(path),
                                  follow ? LIBSSH2_SFTP_STAT : LIBSSH2_SFTP_LSTAT, &a);
    if (rc == 0) attrs_fill(out, &a);
    return sftp_map((LIBSSH2_SFTP *)sftp, rc);
}

int termo_sftp_setstat_perm(TermoSSHSession *s, void *sftp, const char *path, unsigned int mode) {
    if (!s || !sftp) return 0xF000;
    LIBSSH2_SFTP_ATTRIBUTES a;
    memset(&a, 0, sizeof(a));
    a.flags = LIBSSH2_SFTP_ATTR_PERMISSIONS;
    a.permissions = mode & 07777;
    int rc = libssh2_sftp_stat_ex((LIBSSH2_SFTP *)sftp, path, (unsigned)strlen(path),
                                  LIBSSH2_SFTP_SETSTAT, &a);
    return sftp_map((LIBSSH2_SFTP *)sftp, rc);
}

int termo_sftp_mkdir(TermoSSHSession *s, void *sftp, const char *path) {
    if (!s || !sftp) return 0xF000;
    int rc = libssh2_sftp_mkdir_ex((LIBSSH2_SFTP *)sftp, path, (unsigned)strlen(path), 0755);
    return sftp_map((LIBSSH2_SFTP *)sftp, rc);
}

int termo_sftp_rmdir(TermoSSHSession *s, void *sftp, const char *path) {
    if (!s || !sftp) return 0xF000;
    int rc = libssh2_sftp_rmdir_ex((LIBSSH2_SFTP *)sftp, path, (unsigned)strlen(path));
    return sftp_map((LIBSSH2_SFTP *)sftp, rc);
}

int termo_sftp_unlink(TermoSSHSession *s, void *sftp, const char *path) {
    if (!s || !sftp) return 0xF000;
    int rc = libssh2_sftp_unlink_ex((LIBSSH2_SFTP *)sftp, path, (unsigned)strlen(path));
    return sftp_map((LIBSSH2_SFTP *)sftp, rc);
}

int termo_sftp_rename(TermoSSHSession *s, void *sftp, const char *from, const char *to, int overwrite) {
    if (!s || !sftp) return 0xF000;
    long flags = overwrite ? (LIBSSH2_SFTP_RENAME_OVERWRITE | LIBSSH2_SFTP_RENAME_ATOMIC |
                              LIBSSH2_SFTP_RENAME_NATIVE) : 0;
    int rc = libssh2_sftp_rename_ex((LIBSSH2_SFTP *)sftp, from, (unsigned)strlen(from),
                                    to, (unsigned)strlen(to), flags);
    return sftp_map((LIBSSH2_SFTP *)sftp, rc);
}

int termo_sftp_realpath(TermoSSHSession *s, void *sftp, const char *path, char *out, int out_cap) {
    if (!s || !sftp || !out || out_cap <= 0) return 0xF000;
    int rc = libssh2_sftp_realpath((LIBSSH2_SFTP *)sftp, path, out, (unsigned)out_cap - 1);
    if (rc >= 0) { out[rc < out_cap ? rc : out_cap - 1] = '\0'; return 0; }
    return sftp_map((LIBSSH2_SFTP *)sftp, rc);
}

void *termo_sftp_open(TermoSSHSession *s, void *sftp, const char *path, unsigned int pflags) {
    if (!s || !sftp) return NULL;
    // mode 仅在含 CREAT 时用于新文件权限；给 0644 合理默认（落地后由 setstat 继承原权限）。
    return libssh2_sftp_open_ex((LIBSSH2_SFTP *)sftp, path, (unsigned)strlen(path),
                                pflags, 0644, LIBSSH2_SFTP_OPENFILE);
}

void *termo_sftp_opendir(TermoSSHSession *s, void *sftp, const char *path) {
    if (!s || !sftp) return NULL;
    return libssh2_sftp_open_ex((LIBSSH2_SFTP *)sftp, path, (unsigned)strlen(path),
                                0, 0, LIBSSH2_SFTP_OPENDIR);
}

int termo_sftp_fstat(void *handle, TermoSFTPAttrs *out) {
    if (!handle) return 0xF000;
    LIBSSH2_SFTP_ATTRIBUTES a;
    memset(&a, 0, sizeof(a));
    int rc = libssh2_sftp_fstat_ex((LIBSSH2_SFTP_HANDLE *)handle, &a, 0);
    if (rc == 0) { attrs_fill(out, &a); return 0; }
    return 0xF000;
}

long termo_sftp_read(void *handle, unsigned long long offset, char *buf, int len) {
    if (!handle || !buf || len <= 0) return -1;
    libssh2_sftp_seek64((LIBSSH2_SFTP_HANDLE *)handle, offset);
    ssize_t n = libssh2_sftp_read((LIBSSH2_SFTP_HANDLE *)handle, buf, (size_t)len);
    return (long)n;   // >0 字节 / 0 EOF / <0 错误
}

long termo_sftp_write(void *handle, unsigned long long offset, const char *buf, int len) {
    if (!handle || !buf || len < 0) return -1;
    libssh2_sftp_seek64((LIBSSH2_SFTP_HANDLE *)handle, offset);
    size_t off = 0;
    while (off < (size_t)len) {
        ssize_t w = libssh2_sftp_write((LIBSSH2_SFTP_HANDLE *)handle, buf + off, (size_t)len - off);
        if (w < 0) return (long)w;     // 错误
        off += (size_t)w;              // libssh2_sftp_write 可能短写，循环写完
    }
    return (long)off;
}

int termo_sftp_readdir(void *handle, char *name_buf, int name_cap, TermoSFTPAttrs *out) {
    if (!handle || !name_buf || name_cap <= 0) return -1;
    LIBSSH2_SFTP_ATTRIBUTES a;
    memset(&a, 0, sizeof(a));
    int rc = libssh2_sftp_readdir_ex((LIBSSH2_SFTP_HANDLE *)handle, name_buf, (size_t)name_cap - 1,
                                     NULL, 0, &a);
    if (rc > 0) {
        name_buf[rc < name_cap ? rc : name_cap - 1] = '\0';
        attrs_fill(out, &a);
    }
    return rc;   // >0 名长 / 0 EOF / <0 错误
}

void termo_sftp_close(void *handle) {
    if (handle) libssh2_sftp_close_handle((LIBSSH2_SFTP_HANDLE *)handle);
}

