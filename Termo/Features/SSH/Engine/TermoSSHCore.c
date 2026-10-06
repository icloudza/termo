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
#include <poll.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
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

static int knownhost_keytype(int hostkey_type) {
    switch (hostkey_type) {
        case LIBSSH2_HOSTKEY_TYPE_RSA:       return LIBSSH2_KNOWNHOST_KEY_SSHRSA;
        case LIBSSH2_HOSTKEY_TYPE_DSS:       return LIBSSH2_KNOWNHOST_KEY_SSHDSS;
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_256: return LIBSSH2_KNOWNHOST_KEY_ECDSA_256;
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_384: return LIBSSH2_KNOWNHOST_KEY_ECDSA_384;
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_521: return LIBSSH2_KNOWNHOST_KEY_ECDSA_521;
        case LIBSSH2_HOSTKEY_TYPE_ED25519:   return LIBSSH2_KNOWNHOST_KEY_ED25519;
        default: return 0;
    }
}

// 逐行加载 known_hosts。不用 libssh2_knownhost_readfile：它遇到第一行解析不了的内容（@cert-authority、
// sk-* 等新密钥类型）就整体中止，后面的记录全部丢失——那些主机会被当成「未知」反复要求确认。
static void knownhosts_load(LIBSSH2_KNOWNHOSTS *nh, const char *path) {
    if (!path || !*path) return;
    FILE *f = fopen(path, "r");
    if (!f) return;
    char buf[8192];
    while (fgets(buf, sizeof(buf), f)) {
        size_t len = strlen(buf);
        if (len == sizeof(buf) - 1 && buf[len - 1] != '\n') {      // 超长行：丢弃余下部分
            int ch; while ((ch = fgetc(f)) != EOF && ch != '\n') {}
            continue;
        }
        libssh2_knownhost_readline(nh, buf, len, LIBSSH2_KNOWNHOST_FILE_OPENSSH);   // 坏行跳过
    }
    fclose(f);
}

// 对照 known_hosts 校验当前会话的主机密钥。返回 0=匹配 1=未知 2=不匹配 3=该主机只记录了其它类型的密钥。
// 必须按密钥类型比对：不带类型时 libssh2 会拿当前密钥去比该主机的所有记录——known_hosts 里只有 OpenSSH 存的
// ed25519、而 libssh2 协商出 ecdsa 时会被误判为「不匹配」直接拒连。类型不同不等于被篡改，按 3 交给上层提示确认。
// line_out 非空时产出标准 known_hosts 行（供信任写入）。保守：取不到密钥/解析失败按「未知」(1)，绝不误报不匹配。
static const char *known_keytype_algos(int known_type) {
    switch (known_type) {
        case LIBSSH2_KNOWNHOST_KEY_ED25519:   return "ssh-ed25519";
        case LIBSSH2_KNOWNHOST_KEY_ECDSA_256: return "ecdsa-sha2-nistp256";
        case LIBSSH2_KNOWNHOST_KEY_ECDSA_384: return "ecdsa-sha2-nistp384";
        case LIBSSH2_KNOWNHOST_KEY_ECDSA_521: return "ecdsa-sha2-nistp521";
        case LIBSSH2_KNOWNHOST_KEY_SSHRSA:    return "rsa-sha2-512,rsa-sha2-256,ssh-rsa";
        case LIBSSH2_KNOWNHOST_KEY_SSHDSS:    return "ssh-dss";
        default: return NULL;
    }
}

static int hostkey_check_ex(LIBSSH2_SESSION *session, const char *host, int port,
                            const char *real_file, const char *session_file,
                            char *line_out, size_t line_cap,
                            char *known_algos_out, size_t known_algos_cap) {
    if (line_out && line_cap) line_out[0] = '\0';
    if (known_algos_out && known_algos_cap) known_algos_out[0] = '\0';
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
    knownhosts_load(nh, real_file);
    knownhosts_load(nh, session_file);
    struct libssh2_knownhost *kh = NULL;
    const int base = LIBSSH2_KNOWNHOST_TYPE_PLAIN | LIBSSH2_KNOWNHOST_KEYENC_RAW;
    int check = libssh2_knownhost_checkp(nh, host, port, key, keylen, base | knownhost_keytype(keytype), &kh);
    int other_types = 0;
    if (check == LIBSSH2_KNOWNHOST_CHECK_NOTFOUND && knownhost_keytype(keytype) != 0) {
        // 同类型没有记录：再不限类型查一次，区分「全新主机」与「只认识它的其它类型密钥」。
        other_types = libssh2_knownhost_checkp(nh, host, port, key, keylen, base, &kh) == LIBSSH2_KNOWNHOST_CHECK_MISMATCH;
        const char *algos = (other_types && kh) ? known_keytype_algos(kh->typemask & LIBSSH2_KNOWNHOST_KEY_MASK) : NULL;
        if (algos && known_algos_out && known_algos_cap) snprintf(known_algos_out, known_algos_cap, "%s", algos);
    }
    libssh2_knownhost_free(nh);
    if (check == LIBSSH2_KNOWNHOST_CHECK_MATCH)    return 0;
    if (check == LIBSSH2_KNOWNHOST_CHECK_MISMATCH) return 2;
    return other_types ? 3 : 1;   // NOTFOUND / FAILURE → 未知
}

static int hostkey_check(LIBSSH2_SESSION *session, const char *host, int port,
                         const char *real_file, const char *session_file,
                         char *line_out, size_t line_cap) {
    return hostkey_check_ex(session, host, port, real_file, session_file, line_out, line_cap, NULL, 0);
}

// SSH 连接的 socket 选项：
// - TCP_NODELAY：关闭 Nagle。终端按键是小包，Nagle 叠加对端延迟 ACK 会让回显卡顿几十到上百毫秒；
// - 保活：NAT/防火墙悄悄回收空闲连接后能及时发现断线，而不是下次操作时卡死；
//   配了心跳间隔时按它探测，并让「已发出的数据 3 个间隔都没被确认」即断开（等价 OpenSSH ServerAliveCountMax=3）；
// - SO_NOSIGPIPE：对端已断时写入返回 EPIPE，而不是用 SIGPIPE 直接杀掉整个进程。
static void tune_socket(int sock, int keepalive_sec) {
    int on = 1;
    setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &on, sizeof(on));
    setsockopt(sock, SOL_SOCKET, SO_KEEPALIVE, &on, sizeof(on));
    setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
    int idle = keepalive_sec > 0 ? keepalive_sec : 60;
    int intvl = keepalive_sec > 0 ? keepalive_sec : 15;
    int cnt = keepalive_sec > 0 ? 3 : 4;
    setsockopt(sock, IPPROTO_TCP, TCP_KEEPALIVE, &idle, sizeof(idle));
    setsockopt(sock, IPPROTO_TCP, TCP_KEEPINTVL, &intvl, sizeof(intvl));
    setsockopt(sock, IPPROTO_TCP, TCP_KEEPCNT, &cnt, sizeof(cnt));
    if (keepalive_sec > 0) {
        int drop = keepalive_sec * 3 < 15 ? 15 : keepalive_sec * 3;
        setsockopt(sock, IPPROTO_TCP, TCP_RXT_CONNDROPTIME, &drop, sizeof(drop));
    }
}

// 小报文（心跳 / EOF / CLOSE）由 libssh2 用栈上缓冲或通道外缓冲发出：若只发出一半，之后任何发送都会 EAGAIN，
// 直到用同一缓冲补发——栈缓冲早已失效，整条会话就此卡死。只在 socket 确实可写（至少有 SO_SNDLOWAT 空间，
// 小报文一次发完）且 libssh2 没有挂起的出站数据时才发这类报文。
static int ssh_can_send_small(LIBSSH2_SESSION *session, int sock) {
    if (libssh2_session_block_directions(session) & LIBSSH2_SESSION_BLOCK_OUTBOUND) return 0;
    struct pollfd p = { sock, POLLOUT, 0 };
    return poll(&p, 1, 0) > 0 && (p.revents & POLLOUT);
}

// 非阻塞 connect + select 超时（秒）。成功返回已连接的阻塞 socket fd，失败返回 -1。
static int tcp_connect(const char *host, int port, int timeout_sec, int keepalive_sec, char *err, size_t errlen) {
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
    else tune_socket(sock, keepalive_sec);
    return sock;
}

// ── 代理与算法偏好 ──────────────────────────────────────────────────────────
static void px_io_timeout(int sock, int sec) {
    struct timeval tv = { sec, 0 };
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
}
static int px_send(int fd, const void *buf, size_t n) {
    const unsigned char *p = buf;
    while (n > 0) {
        ssize_t w = send(fd, p, n, 0);
        if (w > 0) { p += w; n -= (size_t)w; }
        else if (w < 0 && errno == EINTR) continue;
        else return -1;
    }
    return 0;
}
static int px_recv(int fd, void *buf, size_t n) {
    unsigned char *p = buf;
    while (n > 0) {
        ssize_t r = recv(fd, p, n, 0);
        if (r > 0) { p += r; n -= (size_t)r; }
        else if (r < 0 && errno == EINTR) continue;
        else return -1;
    }
    return 0;
}

static const char *socks5_reply_text(int rep) {
    switch (rep) {
        case 1: return "代理服务器内部错误";
        case 2: return "代理规则不允许该连接";
        case 3: return "代理到目标网络不可达";
        case 4: return "代理到目标主机不可达";
        case 5: return "目标主机拒绝连接";
        case 6: return "代理连接目标超时";
        default: return "代理拒绝了连接请求";
    }
}

// 在已连上代理的 socket 上建立到 host:port 的隧道。成功返回 0，失败写 err 返回 -1。
static int proxy_negotiate(int fd, const TermoSSHOptions *o, const char *host, int port, char *err, size_t errlen) {
    size_t hlen = strlen(host);
    const char *user = (o->proxy_user && *o->proxy_user) ? o->proxy_user : NULL;
    const char *pass = o->proxy_pass ? o->proxy_pass : "";
    if (o->proxy_type == 1) {                                   // SOCKS5，目标用域名交给代理解析（不泄漏本地 DNS）
        if (hlen > 255) { snprintf(err, errlen, "主机名过长，代理无法转发"); return -1; }
        unsigned char g[4] = { 5, (unsigned char)(user ? 2 : 1), 0x00, 0x02 };
        if (px_send(fd, g, user ? 4 : 3)) goto io;
        unsigned char m[2];
        if (px_recv(fd, m, 2) || m[0] != 5) goto proto;
        if (m[1] == 0x02) {
            if (!user) { snprintf(err, errlen, "代理要求用户名密码认证"); return -1; }
            size_t ul = strlen(user), pl = strlen(pass);
            if (ul > 255 || pl > 255) { snprintf(err, errlen, "代理用户名或密码过长"); return -1; }
            unsigned char a[515]; size_t n = 0;
            a[n++] = 1; a[n++] = (unsigned char)ul; memcpy(a + n, user, ul); n += ul;
            a[n++] = (unsigned char)pl; memcpy(a + n, pass, pl); n += pl;
            if (px_send(fd, a, n)) goto io;
            unsigned char r[2];
            if (px_recv(fd, r, 2)) goto io;
            if (r[1] != 0) { snprintf(err, errlen, "代理认证失败：用户名或密码错误"); return -1; }
        } else if (m[1] != 0x00) {
            snprintf(err, errlen, "代理不接受可用的认证方式"); return -1;
        }
        unsigned char q[262]; size_t n = 0;
        q[n++] = 5; q[n++] = 1; q[n++] = 0; q[n++] = 3; q[n++] = (unsigned char)hlen;
        memcpy(q + n, host, hlen); n += hlen;
        q[n++] = (unsigned char)(port >> 8); q[n++] = (unsigned char)(port & 0xff);
        if (px_send(fd, q, n)) goto io;
        unsigned char h4[4];
        if (px_recv(fd, h4, 4) || h4[0] != 5) goto proto;
        if (h4[1] != 0) { snprintf(err, errlen, "%s", socks5_reply_text(h4[1])); return -1; }
        size_t skip = h4[3] == 1 ? 4 : (h4[3] == 4 ? 16 : 0);
        if (h4[3] == 3) { unsigned char l; if (px_recv(fd, &l, 1)) goto io; skip = l; }
        unsigned char tmp[260];
        if (px_recv(fd, tmp, skip + 2)) goto io;                // 绑定地址 + 端口，丢弃
        return 0;
    }
    if (o->proxy_type == 2) {                                   // SOCKS4a
        size_t ul = user ? strlen(user) : 0;
        if (hlen > 255 || ul > 255) { snprintf(err, errlen, "主机名或用户名过长，代理无法转发"); return -1; }
        unsigned char q[530]; size_t n = 0;
        q[n++] = 4; q[n++] = 1; q[n++] = (unsigned char)(port >> 8); q[n++] = (unsigned char)(port & 0xff);
        q[n++] = 0; q[n++] = 0; q[n++] = 0; q[n++] = 1;           // 0.0.0.1 = 由代理解析域名
        if (ul) { memcpy(q + n, user, ul); n += ul; }
        q[n++] = 0;
        memcpy(q + n, host, hlen); n += hlen; q[n++] = 0;
        if (px_send(fd, q, n)) goto io;
        unsigned char r[8];
        if (px_recv(fd, r, 8)) goto io;
        if (r[1] != 0x5A) { snprintf(err, errlen, "SOCKS4 代理拒绝了连接请求"); return -1; }
        return 0;
    }
    if (o->proxy_type == 3) {                                   // HTTP CONNECT
        char target[300];
        snprintf(target, sizeof(target), strchr(host, ':') ? "[%s]:%d" : "%s:%d", host, port);
        char auth[1200] = "";
        if (user) {
            char cred[600]; snprintf(cred, sizeof(cred), "%s:%s", user, pass);
            char b64[820]; b64_pad((const unsigned char *)cred, strlen(cred), b64, sizeof(b64));
            snprintf(auth, sizeof(auth), "Proxy-Authorization: Basic %s\r\n", b64);
        }
        char req[1600];
        int len = snprintf(req, sizeof(req), "CONNECT %s HTTP/1.1\r\nHost: %s\r\n%s\r\n", target, target, auth);
        if (len <= 0 || (size_t)len >= sizeof(req) || px_send(fd, req, (size_t)len)) goto io;
        char resp[4096]; size_t n = 0;
        while (n < sizeof(resp) - 1) {                         // 逐字节读到头部结束，不多读隧道里的 SSH 数据
            if (px_recv(fd, resp + n, 1)) goto io;
            n++;
            if (n >= 4 && memcmp(resp + n - 4, "\r\n\r\n", 4) == 0) break;
        }
        resp[n] = '\0';
        int code = 0;
        if (sscanf(resp, "HTTP/%*s %d", &code) != 1) goto proto;
        if (code == 200) return 0;
        if (code == 407) { snprintf(err, errlen, "HTTP 代理需要认证或认证失败（407）"); return -1; }
        snprintf(err, errlen, "HTTP 代理拒绝了连接请求（%d）", code);
        return -1;
    }
    snprintf(err, errlen, "代理地址格式无效（支持 socks5:// socks4:// http://）");
    return -1;
io:
    snprintf(err, errlen, "与代理服务器通信失败或超时");
    return -1;
proto:
    snprintf(err, errlen, "代理服务器响应异常（请确认代理类型是否正确）");
    return -1;
}

// 建立到目标的 TCP 连接：配置了代理则先连代理再握手隧道。返回阻塞 socket，失败 -1。
static int open_transport(const char *host, int port, const TermoSSHOptions *o, int default_timeout,
                          char *err, size_t errlen) {
    int timeout = (o && o->connect_timeout_sec > 0) ? o->connect_timeout_sec : default_timeout;
    int ka = o ? o->keepalive_sec : 0;
    if (!o || o->proxy_type == 0) return tcp_connect(host, port, timeout, ka, err, errlen);
    if (o->proxy_type < 0 || !o->proxy_host || !*o->proxy_host) {
        snprintf(err, errlen, "代理地址格式无效（支持 socks5:// socks4:// http://），已拒绝直连");
        return -1;
    }
    char perr[160];
    int sock = tcp_connect(o->proxy_host, o->proxy_port, timeout, ka, perr, sizeof(perr));
    if (sock < 0) { snprintf(err, errlen, "连接代理 %s:%d 失败或超时", o->proxy_host, o->proxy_port); return -1; }
    px_io_timeout(sock, timeout);
    if (proxy_negotiate(sock, o, host, port, err, errlen) != 0) { close(sock); return -1; }
    px_io_timeout(sock, 0);
    return sock;
}

// 握手前应用算法偏好（libssh2 会过滤掉不支持的项；一个都不支持则报错，而不是静默改用默认算法）。
static int apply_method_prefs(LIBSSH2_SESSION *session, const TermoSSHOptions *o, char *err, size_t errlen) {
    if (!o) return 0;
    struct { int type; const char *val; const char *label; } prefs[] = {
        { LIBSSH2_METHOD_CRYPT_CS, o->ciphers, "Cipher" },
        { LIBSSH2_METHOD_CRYPT_SC, o->ciphers, "Cipher" },
        { LIBSSH2_METHOD_KEX, o->kex, "密钥交换" },
        { LIBSSH2_METHOD_HOSTKEY, o->hostkey_algos, "主机密钥" },
    };
    for (size_t i = 0; i < sizeof(prefs) / sizeof(prefs[0]); i++) {
        if (!prefs[i].val || !*prefs[i].val) continue;
        if (libssh2_session_method_pref(session, prefs[i].type, prefs[i].val) != 0) {
            snprintf(err, errlen, "不支持所选的%s算法：%s", prefs[i].label, prefs[i].val);
            return -1;
        }
    }
    return 0;
}

/// 用 SSH Agent 里的身份逐个尝试认证。成功返回 0。
/// 失败时 msg 写原因、返回值区分两类：服务器不接受任何密钥 / 用户在授权提示里取消 → LIBSSH2_ERROR_AUTHENTICATION_FAILED，
/// 上层视为不可重试（否则断线重连会一遍遍弹 Touch ID）；连不上 agent → 其它错误码，可等 agent 就绪后重试。
static int agent_userauth(LIBSSH2_SESSION *session, const char *user, const char *agent_path,
                          char *msg, size_t msglen) {
    LIBSSH2_AGENT *agent = libssh2_agent_init(session);
    if (!agent) { snprintf(msg, msglen, "无法初始化 SSH Agent"); return LIBSSH2_ERROR_ALLOC; }
    if (agent_path && *agent_path) libssh2_agent_set_identity_path(agent, agent_path);
    const char *where = (agent_path && *agent_path) ? agent_path : "SSH_AUTH_SOCK";

    int rc = libssh2_agent_connect(agent);
    if (rc) {
        snprintf(msg, msglen, "无法连接 SSH Agent（%s），请确认 Agent 已启动", where);
        goto done;
    }
    rc = libssh2_agent_list_identities(agent);
    if (rc) {
        snprintf(msg, msglen, "读取 SSH Agent 中的密钥失败（%s）", where);
        goto done;
    }

    struct libssh2_agent_publickey *id = NULL, *prev = NULL;
    int tried = 0, refused = 0;
    rc = LIBSSH2_ERROR_AUTHENTICATION_FAILED;
    for (;;) {
        int r = libssh2_agent_get_identity(agent, &id, prev);
        if (r != 0) break;                     // 1 = 没有更多身份，<0 = 出错
        tried++;
        int a = libssh2_agent_userauth(agent, user ? user : "", id);
        if (a == 0) { rc = 0; break; }
        // agent 拒绝签名（授权提示被取消、Agent 已锁定）：libssh2 报 PUBLICKEY_UNVERIFIED「Callback returned error」
        char *le = NULL; libssh2_session_last_error(session, &le, NULL, 0);
        if (a == LIBSSH2_ERROR_AGENT_PROTOCOL || (le && strstr(le, "Callback returned error"))) refused = 1;
        if (a == LIBSSH2_ERROR_SOCKET_DISCONNECT || a == LIBSSH2_ERROR_SOCKET_SEND
            || a == LIBSSH2_ERROR_SOCKET_RECV || a == LIBSSH2_ERROR_TIMEOUT) { rc = a; break; }   // 网络问题，可重试
        prev = id;
    }
    if (rc == LIBSSH2_ERROR_AUTHENTICATION_FAILED) {
        if (tried == 0) snprintf(msg, msglen, "SSH Agent 中没有可用的密钥（%s）", where);
        else if (refused) snprintf(msg, msglen, "SSH Agent 拒绝签名（可能在授权提示中取消，或 Agent 已锁定）");
        else snprintf(msg, msglen, "服务器未接受 SSH Agent 中的任何密钥（已尝试 %d 个）", tried);
    } else if (rc) {
        char *e = NULL; libssh2_session_last_error(session, &e, NULL, 0);
        snprintf(msg, msglen, "%s", e ? e : "");
    }
done:
    libssh2_agent_disconnect(agent);
    libssh2_agent_free(agent);
    return rc;
}

/// 按主机设置认证：SSH Agent / 私钥文件 / 密码。成功返回 0，失败返回 libssh2 错误码并写原因。
static int do_userauth(LIBSSH2_SESSION *session, const char *user, const char *password,
                       const char *key_path, const char *key_passphrase,
                       const TermoSSHOptions *opts, char *msg, size_t msglen) {
    msg[0] = 0;
    int rc;
    if (opts && opts->use_agent) {
        return agent_userauth(session, user, opts->agent_path, msg, msglen);
    } else if (key_path && *key_path) {
        rc = libssh2_userauth_publickey_fromfile(session, user ? user : "", NULL,
                                                 key_path, key_passphrase ? key_passphrase : "");
    } else {
        rc = libssh2_userauth_password(session, user ? user : "", password ? password : "");
    }
    if (rc) {
        char *e = NULL; libssh2_session_last_error(session, &e, NULL, 0);
        snprintf(msg, msglen, "%s", e ? e : "");
    }
    return rc;
}

// ── 持久会话 ────────────────────────────────────────────────────────────────
struct TermoSSHSession {
    int sock;
    int keepalive_sec;     // 主机设置的心跳间隔（终端 shell 泵据此发 SSH 心跳）
    LIBSSH2_SESSION *session;
    char fp_sha256[80];
    char fp_md5[64];
    volatile int cancel;   // 流式读取的中止标志（另一线程置位）
};

TermoSSHSession *termo_ssh_open(const char *host, int port,
                                const char *user, const char *password,
                                const char *key_path, const char *key_passphrase,
                                const char *real_known_hosts, const char *session_known_hosts,
                                const TermoSSHOptions *opts,
                                char *err, int errlen) {
    libssh2_init(0);   // 引用计数，安全重复调用
    int sock = open_transport(host ? host : "", port, opts, 10, err, (size_t)errlen);
    if (sock < 0) return NULL;

    LIBSSH2_SESSION *session = libssh2_session_init();
    if (!session) {
        snprintf(err, (size_t)errlen, "libssh2_session_init 失败");
        close(sock);
        return NULL;
    }
    libssh2_session_set_blocking(session, 1);
    libssh2_session_set_timeout(session, 15000);
    if (apply_method_prefs(session, opts, err, (size_t)errlen)) {
        libssh2_session_free(session);       // 尚未握手：不能走 fail 里的 disconnect（会往未绑定的 fd 发包）
        close(sock);
        return NULL;
    }

    int rc = libssh2_session_handshake(session, sock);
    if (rc) {
        char *msg = NULL; libssh2_session_last_error(session, &msg, NULL, 0);
        snprintf(err, (size_t)errlen, "握手失败 (%d)：%s", rc, msg ? msg : "");
        goto fail;
    }

    // 认证前校验主机密钥，绝不把密码/密钥签名送给未经确认的服务器：不匹配（疑似 MITM）拒绝；
    // 未知或密钥类型变了也拒绝——首次连接必须先经指纹核对弹窗确认（写入 known_hosts 或本次会话信任），
    // 否则监控、探测、文件、转发等后台连接会在用户确认前就向冒名主机认证。
    if ((real_known_hosts && *real_known_hosts) || (session_known_hosts && *session_known_hosts)) {
        int hk = hostkey_check(session, host ? host : "", port, real_known_hosts, session_known_hosts, NULL, 0);
        if (hk == 2) {
            snprintf(err, (size_t)errlen, "HOSTKEY_MISMATCH 主机密钥与已知记录不匹配（疑似中间人攻击），已拒绝连接");
            goto fail;
        }
        if (hk != 0) {
            snprintf(err, (size_t)errlen, "HOSTKEY_UNVERIFIED 尚未确认该主机的指纹，已拒绝连接");
            goto fail;
        }
    }

    char amsg[200];
    rc = do_userauth(session, user, password, key_path, key_passphrase, opts, amsg, sizeof(amsg));
    if (rc) {
        snprintf(err, (size_t)errlen, "认证失败 (%d)：%s", rc, amsg);
        goto fail;
    }

    TermoSSHSession *s = calloc(1, sizeof(*s));
    if (!s) { snprintf(err, (size_t)errlen, "分配失败"); goto fail; }
    s->sock = sock;
    s->keepalive_sec = opts ? opts->keepalive_sec : 0;
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
                    const char *real_known_hosts, const char *session_known_hosts,
                    const TermoSSHOptions *opts,
                    TermoSSHStageCallback on_stage, void *ud) {
    if (!on_stage) return;
    #define STAGE(n, ok, msg) on_stage(ud, (n), (ok), (msg))
    libssh2_init(0);

    int sock = -1;
    if (opts && opts->proxy_type != 0) {
        // 经代理：目标地址由代理解析（内网名只有代理那边能解析），1/2 阶段合并为「连接代理并建立隧道」
        STAGE(1, 1, "经代理连接，目标地址由代理解析");
        char perr[200];
        sock = open_transport(host ? host : "", port, opts, 10, perr, sizeof(perr));
        if (sock < 0) { STAGE(2, 0, perr); return; }
        STAGE(2, 1, NULL);
        goto handshake;
    }

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
    int ctimeout = (opts && opts->connect_timeout_sec > 0) ? opts->connect_timeout_sec : 10;
    for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
        sock = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (sock < 0) continue;
        int flags = fcntl(sock, F_GETFL, 0);
        fcntl(sock, F_SETFL, flags | O_NONBLOCK);
        int rc = connect(sock, ai->ai_addr, ai->ai_addrlen);
        if (rc == 0) { fcntl(sock, F_SETFL, flags); break; }
        if (errno == EINPROGRESS) {
            fd_set wf; FD_ZERO(&wf); FD_SET(sock, &wf);
            struct timeval tv = { ctimeout, 0 };
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
    tune_socket(sock, opts ? opts->keepalive_sec : 0);
    STAGE(2, 1, NULL);

handshake: ;
    // 3. SSH 协议握手
    LIBSSH2_SESSION *session = libssh2_session_init();
    if (!session) { STAGE(3, 0, "libssh2 初始化失败"); close(sock); return; }
    libssh2_session_set_blocking(session, 1);
    libssh2_session_set_timeout(session, 15000);
    {
        char perr[200];
        if (apply_method_prefs(session, opts, perr, sizeof(perr))) {
            STAGE(3, 0, perr); libssh2_session_free(session); close(sock); return;
        }
    }
    int rc = libssh2_session_handshake(session, sock);
    if (rc) {
        char *e = NULL; libssh2_session_last_error(session, &e, NULL, 0);
        char m[220]; snprintf(m, sizeof(m), "SSH 握手失败 (%d)：%s", rc, e ? e : "");
        STAGE(3, 0, m);
        libssh2_session_free(session); close(sock); return;
    }
    // 认证前核对主机密钥（调用方先做过指纹确认）：不在 known_hosts 里就不发凭据。
    if ((real_known_hosts && *real_known_hosts) || (session_known_hosts && *session_known_hosts)) {
        int hk = hostkey_check(session, host ? host : "", port, real_known_hosts, session_known_hosts, NULL, 0);
        if (hk != 0) {
            STAGE(3, 0, hk == 2 ? "主机密钥与已知记录不匹配（疑似中间人攻击），未发送凭据"
                                : "尚未确认该主机的指纹，未发送凭据");
            libssh2_session_disconnect(session, "hostkey"); libssh2_session_free(session); close(sock); return;
        }
    }
    STAGE(3, 1, NULL);

    // 4. 身份验证
    char amsg[200];
    rc = do_userauth(session, user, password, key_path, key_passphrase, opts, amsg, sizeof(amsg));
    if (rc) {
        char m[220]; snprintf(m, sizeof(m), "身份验证失败 (%d)：%s", rc, amsg);
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
                            const TermoSSHOptions *opts,
                            TermoHostKeyScan *out) {
    if (!out) return;
    memset(out, 0, sizeof(*out));
    out->status = -1;
    libssh2_init(0);
    char errbuf[160];
    int sock = open_transport(host ? host : "", port, opts, 8, errbuf, sizeof(errbuf));   // 与真实连接走同一代理
    if (sock < 0) return;
    LIBSSH2_SESSION *session = libssh2_session_init();
    if (!session) { close(sock); return; }
    libssh2_session_set_blocking(session, 1);
    libssh2_session_set_timeout(session, 8000);
    // 主机密钥算法偏好与真实连接一致，扫到的密钥类型才对得上
    if (apply_method_prefs(session, opts, errbuf, sizeof(errbuf)) == 0 &&
        libssh2_session_handshake(session, sock) == 0) {     // 仅握手，不认证
        fill_fingerprints(session, out->sha256, sizeof(out->sha256), out->md5, sizeof(out->md5));
        out->status = hostkey_check_ex(session, host ? host : "", port,
                                       real_known_hosts, session_known_hosts,
                                       out->line, sizeof(out->line),
                                       out->known_algos, sizeof(out->known_algos));
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
    // want_reply=0：服务器对心跳的回应 libssh2 只挂进内部包链表、从不释放，开着会随会话时长无限堆积。
    // 断线检测靠 TCP 层（tune_socket 设的重传超时），心跳只负责让空闲连接持续有流量。
    if (sh->s->keepalive_sec > 0) libssh2_keepalive_config(session, 0, (unsigned)sh->s->keepalive_sec);
    char rbuf[16384];
    int errored = 0;
    int resize_resumed = 0;

    while (!sh->stop) {
        int progressed = 0;

        if (sh->resize_pending) {
            sh->resize_pending = 0;
            int rc = libssh2_channel_request_pty_size(sh->ch, sh->cols, sh->rows);
            if (rc == LIBSSH2_ERROR_EAGAIN) {
                // 非阻塞下发送未完成：libssh2 留着这次的报文，下次调用会先把它（可能是旧尺寸）发完。
                // 必须重试而不能丢弃，否则远端停在旧尺寸；补发成功后再发一次最新尺寸。
                sh->resize_pending = 1;
                resize_resumed = 1;
            } else if (resize_resumed) {
                resize_resumed = 0;
                sh->resize_pending = 1;
            }
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

        // 空闲时按心跳间隔发 SSH 心跳（libssh2 自己按间隔节流）。只在没有挂起的写/尺寸请求时发：
        // 心跳用栈上缓冲发包，若只发出一半，别的发送都会 EAGAIN 直到同一缓冲补发——而那块栈内存已经没了。
        if (sh->s->keepalive_sec > 0 && !sh->resize_pending && !resize_resumed && ssh_can_send_small(session, sock)) {
            pthread_mutex_lock(&sh->lock);
            int idle_w = sh->wlen == 0;
            pthread_mutex_unlock(&sh->lock);
            if (idle_w) {
                int next = 0;
                int rc = libssh2_keepalive_send(session, &next);
                if (rc < 0 && rc != LIBSSH2_ERROR_EAGAIN) { errored = 1; break; }
            }
        }

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

TermoSSHShell *termo_ssh_shell_open(TermoSSHSession *s, int cols, int rows, const char *lc_all,
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
    if (lc_all && *lc_all) libssh2_channel_setenv(ch, "LC_ALL", lc_all);   // 被拒绝不影响后续
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
// 一条隧道 = 一条 SSH 会话 + 一个转发线程，线程里用 select 驱动所有连接，全程非阻塞：
// SOCKS5 握手、开 direct-tcpip 通道、-R 连本地目标都是按连接推进的状态机，
// 任何一个慢连接（端口探测、不发握手的客户端、目标迟迟不响应）都不会冻结同一隧道里的其它连接。
#define FWD_MAX_CONN 128
#define FWD_BUF 16384
#define FWD_SETUP_TIMEOUT_MS 10000           // 握手 / 开通道 / 连本地目标的超时

enum { CS_SOCKS = 1, CS_OPEN, CS_CONNECT, CS_ACTIVE };

typedef struct {
    int state;
    int local_fd;
    LIBSSH2_CHANNEL *ch;
    long since_ms;                       // 进入当前建立阶段的时间
    unsigned long seq;                   // 排队开通道的先后
    unsigned char hs[600]; size_t hs_len;   // SOCKS5 握手收包缓冲
    int socks_stage;                     // 0 等问候 1 等连接请求
    char dhost[256]; int dport;          // 要开的通道目标
    long open_started_ms;                // 成为 opening（真正开始开通道）的时间
    int abandoned;                       // 开通道超时：本地已断开，通道开好后直接释放
    struct sockaddr_storage addrs[4];    // -R 本地目标的候选地址（localhost 常先解析出 ::1，服务却只听 127.0.0.1）
    socklen_t addrlens[4];
    int naddr, addr_idx;
    char l2s[FWD_BUF]; size_t l2s_len;   // local→ssh 待写
    char s2l[FWD_BUF]; size_t s2l_len;   // ssh→local 待写
    int local_eof, ssh_eof, sent_eof;
    int write_pending;                   // 上次 channel_write 返回 EAGAIN：libssh2 正挂着这条连接的半发包
    int closing;                         // 待关闭：先用同一缓冲把挂起的写补发完，再释放通道
    int freeing;                         // 本地已关，channel_free 返回 EAGAIN（CLOSE 未发完/未收到回应），逐轮重试
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
    ForwardConn *conns[FWD_MAX_CONN];    // 按需分配（每条 32KB 缓冲），空闲隧道不占内存
    ForwardConn *opening;                // 正在开通道的连接：libssh2 的 direct-tcpip 状态是整条会话共用的，同一时刻只能开一个
    unsigned long next_seq;
};

static void fwd_wake(TermoSSHForward *f) { char x = 'x'; ssize_t r = write(f->wake[1], &x, 1); (void)r; }

static void set_nonblock(int fd) { int fl = fcntl(fd, F_GETFL, 0); fcntl(fd, F_SETFL, fl | O_NONBLOCK); }

static void prep_local_fd(int fd) {
    set_nonblock(fd);
    int on = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
}

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

// -R：解析本地目标的全部地址（最多 4 个），之后逐个非阻塞连接。
static int resolve_local_target(const char *host, int port, struct sockaddr_storage *addrs, socklen_t *lens, int cap) {
    char portstr[16]; snprintf(portstr, sizeof(portstr), "%d", port);
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, portstr, &hints, &res) != 0 || !res) return 0;
    int n = 0;
    for (struct addrinfo *ai = res; ai && n < cap; ai = ai->ai_next) {
        if (ai->ai_addrlen > sizeof(addrs[0])) continue;
        memcpy(&addrs[n], ai->ai_addr, ai->ai_addrlen);
        lens[n] = ai->ai_addrlen;
        n++;
    }
    freeaddrinfo(res);
    return n;
}

// 从 c->addr_idx 起逐个发起非阻塞连接：立即连上返回 1，进行中返回 0（等可写），全部失败返回 -1。
static int start_local_connect(ForwardConn *c) {
    for (; c->addr_idx < c->naddr; c->addr_idx++) {
        struct sockaddr *sa = (struct sockaddr *)&c->addrs[c->addr_idx];
        int fd = socket(sa->sa_family, SOCK_STREAM, 0);
        if (fd < 0) continue;
        prep_local_fd(fd);
        if (connect(fd, sa, c->addrlens[c->addr_idx]) == 0) { c->local_fd = fd; return 1; }
        if (errno == EINPROGRESS) { c->local_fd = fd; c->since_ms = termo_now_ms(); return 0; }
        close(fd);
    }
    return -1;
}

static void socks5_reply(int fd, int rep) {
    unsigned char r[10] = { 0x05, (unsigned char)rep, 0x00, 0x01, 0,0,0,0, 0,0 };
    ssize_t w = send(fd, r, sizeof(r), 0); (void)w;    // 10 字节，刚建立的连接发送缓冲一定放得下
}

static ForwardConn *fwd_new_conn(TermoSSHForward *f, int local_fd, int state) {
    for (int i = 0; i < FWD_MAX_CONN; i++) {
        if (f->conns[i]) continue;
        ForwardConn *c = calloc(1, sizeof(*c));
        if (!c) return NULL;
        c->state = state;
        c->local_fd = local_fd;
        c->since_ms = termo_now_ms();
        f->conns[i] = c;
        return c;
    }
    return NULL;
}

// 释放连接。非阻塞下 channel_free 可能 EAGAIN：此时 CLOSE 报文可能只发出一半，必须逐轮重试直到完成，
// 否则挂起的半发包会让这条会话之后所有发送都 EAGAIN（整个隧道卡死），通道也会泄漏。
static void conn_close(TermoSSHForward *f, int i) {
    ForwardConn *c = f->conns[i];
    if (f->opening == c) f->opening = NULL;              // 正常流程不会走到；防御，绝不留下悬空指针
    if (c->local_fd >= 0) { close(c->local_fd); c->local_fd = -1; }
    if (c->ch) {
        // channel_free 会补发 EOF（栈上缓冲）和 CLOSE：发送空间不足时先挂起，下轮再试，避免只发出半个报文
        if (!ssh_can_send_small(f->s->session, f->s->sock) ||
            libssh2_channel_free(c->ch) == LIBSSH2_ERROR_EAGAIN) {
            c->freeing = 1; c->closing = 0; c->state = 0;   // 退出建立/转发状态机，只等释放完成
            return;
        }
    }
    free(c);
    f->conns[i] = NULL;
}

// 把待写的 local→ssh 数据交给通道。libssh2 规则：一条报文只发出一半（EAGAIN）时，必须用**同一缓冲**重试把它发完，
// 期间别的发送一律 EAGAIN——所以 l2s 只在写成功后才挪动，挂起时也不能丢弃这条连接。
static void conn_flush_l2s(ForwardConn *c) {
    while (c->l2s_len > 0) {
        ssize_t w = libssh2_channel_write(c->ch, c->l2s, c->l2s_len);
        if (w > 0) {
            memmove(c->l2s, c->l2s + w, c->l2s_len - (size_t)w); c->l2s_len -= (size_t)w;
            c->write_pending = 0;
        } else if (w == LIBSSH2_ERROR_EAGAIN) {
            c->write_pending = 1; return;
        } else {                                         // 通道已关/出错：数据无处可去
            c->l2s_len = 0; c->write_pending = 0; c->local_eof = 1; return;
        }
    }
}

// 已建立连接的双向泵（非阻塞）。返回 -1 表示该连接可以释放。
static int conn_pump(ForwardConn *c, LIBSSH2_SESSION *session, int sock, int *progress) {
    if (c->closing) {                                    // 只补发挂起的写，补完即可释放
        conn_flush_l2s(c);
        return c->write_pending ? 0 : -1;
    }
    // local → ssh
    if (!c->local_eof && c->l2s_len < FWD_BUF) {
        ssize_t n = recv(c->local_fd, c->l2s + c->l2s_len, FWD_BUF - c->l2s_len, 0);
        if (n > 0) c->l2s_len += (size_t)n;
        else if (n == 0) c->local_eof = 1;
        else if (errno != EAGAIN && errno != EWOULDBLOCK) c->local_eof = 1;
    }
    conn_flush_l2s(c);
    if (c->local_eof && c->l2s_len == 0 && !c->sent_eof && !c->write_pending && ssh_can_send_small(session, sock)) {
        int rc = libssh2_channel_send_eof(c->ch);       // EOF 报文在栈上：只在发送空间足够时发，见 ssh_can_send_small
        if (rc != LIBSSH2_ERROR_EAGAIN) c->sent_eof = 1;
    }

    // ssh → local
    if (c->s2l_len < FWD_BUF) {
        ssize_t n = libssh2_channel_read(c->ch, c->s2l + c->s2l_len, FWD_BUF - c->s2l_len);
        if (n > 0) { c->s2l_len += (size_t)n; *progress = 1; }   // libssh2 内部可能还缓着数据：下轮不等 socket 事件
        else if (n == 0) c->ssh_eof = 1;             // EOF
        else if (n != LIBSSH2_ERROR_EAGAIN) c->ssh_eof = 1;
    }
    while (c->s2l_len > 0) {
        ssize_t w = send(c->local_fd, c->s2l, c->s2l_len, 0);
        if (w > 0) { memmove(c->s2l, c->s2l + w, c->s2l_len - (size_t)w); c->s2l_len -= (size_t)w; }
        else if (w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
        else { c->s2l_len = 0; c->ssh_eof = 1; break; }   // 本地写错误 → 关
    }
    // 远端 EOF 且下行数据已全部交给本地 → 关整条连接（本地先半关闭的客户端也要等响应发完）；
    // 挂着半发包的先进入 closing 补发完再释放。
    if (c->ssh_eof && c->s2l_len == 0) {
        if (!c->write_pending) return -1;
        c->closing = 1;
    }
    return 0;
}

// SOCKS5 握手推进一步（本地可读时调用）。返回 1=握手完成（目标已写入 dhost/dport），0=还要等数据，-1=失败应关闭。
static int socks5_step(ForwardConn *c) {
    if (c->hs_len < sizeof(c->hs)) {
        ssize_t n = recv(c->local_fd, c->hs + c->hs_len, sizeof(c->hs) - c->hs_len, 0);
        if (n == 0) return -1;
        if (n < 0) return (errno == EAGAIN || errno == EWOULDBLOCK) ? 0 : -1;
        c->hs_len += (size_t)n;
    }
    for (;;) {
        if (c->socks_stage == 0) {                       // VER NMETHODS METHODS…
            if (c->hs_len < 2) return 0;
            if (c->hs[0] != 0x05) return -1;
            size_t need = 2 + (size_t)c->hs[1];
            if (c->hs_len < need) return 0;
            unsigned char rep[2] = { 0x05, 0x00 };       // 选「无认证」
            if (send(c->local_fd, rep, 2, 0) != 2) return -1;
            memmove(c->hs, c->hs + need, c->hs_len - need); c->hs_len -= need;
            c->socks_stage = 1;
            continue;
        }
        if (c->hs_len < 4) return 0;                     // VER CMD RSV ATYP …
        if (c->hs[0] != 0x05) return -1;
        if (c->hs[1] != 0x01) { socks5_reply(c->local_fd, 0x07); return -1; }   // 只支持 CONNECT
        size_t need;
        switch (c->hs[3]) {
            case 0x01: need = 4 + 4 + 2; break;
            case 0x04: need = 4 + 16 + 2; break;
            case 0x03:
                if (c->hs_len < 5) return 0;
                need = 4 + 1 + (size_t)c->hs[4] + 2;
                break;
            default: socks5_reply(c->local_fd, 0x08); return -1;
        }
        if (c->hs_len < need) return 0;
        const unsigned char *a = c->hs + 4;
        if (c->hs[3] == 0x01) {
            snprintf(c->dhost, sizeof(c->dhost), "%d.%d.%d.%d", a[0], a[1], a[2], a[3]);
        } else if (c->hs[3] == 0x04) {
            snprintf(c->dhost, sizeof(c->dhost), "%x:%x:%x:%x:%x:%x:%x:%x",
                     (a[0]<<8)|a[1], (a[2]<<8)|a[3], (a[4]<<8)|a[5], (a[6]<<8)|a[7],
                     (a[8]<<8)|a[9], (a[10]<<8)|a[11], (a[12]<<8)|a[13], (a[14]<<8)|a[15]);
        } else {
            size_t l = c->hs[4];
            memcpy(c->dhost, c->hs + 5, l); c->dhost[l] = '\0';
        }
        c->dport = (c->hs[need - 2] << 8) | c->hs[need - 1];
        // 极少数客户端不等应答就开始发数据：多出来的字节留作通道建好后的首批上行数据
        size_t extra = c->hs_len - need;
        if (extra > 0) { memcpy(c->l2s, c->hs + need, extra); c->l2s_len = extra; }
        c->hs_len = 0;
        return 1;
    }
}

// 推进「开通道」：同一会话同一时刻只开一个（libssh2 direct-tcpip 状态是会话级的，必须用同样参数重试直到有结果）。
static void advance_open(TermoSSHForward *f, LIBSSH2_SESSION *session, long now) {
    if (!f->opening) {
        ForwardConn *next = NULL;
        for (int i = 0; i < FWD_MAX_CONN; i++) {
            ForwardConn *c = f->conns[i];
            if (c && c->state == CS_OPEN && !c->freeing && (!next || c->seq < next->seq)) next = c;
        }
        if (!next) return;
        f->opening = next;
        next->open_started_ms = now;                      // 开通道本身的超时从这里算起
    }
    ForwardConn *c = f->opening;
    LIBSSH2_CHANNEL *ch = libssh2_channel_direct_tcpip_ex(session, c->dhost, c->dport, "127.0.0.1", 0);
    if (!ch && libssh2_session_last_errno(session) == LIBSSH2_ERROR_EAGAIN) {
        // 超时：断开本地客户端，但这次开通道仍要等到出结果（中途放弃会让下一次开通道错用这次的目标）
        if (!c->abandoned && now - c->open_started_ms > FWD_SETUP_TIMEOUT_MS) {
            if (f->kind == 2 && c->local_fd >= 0) socks5_reply(c->local_fd, 0x04);
            if (c->local_fd >= 0) { close(c->local_fd); c->local_fd = -1; }
            c->abandoned = 1;
        }
        return;
    }
    f->opening = NULL;
    if (ch && !c->abandoned) {
        c->ch = ch;
        if (f->kind == 2) socks5_reply(c->local_fd, 0x00);
        c->state = CS_ACTIVE;
        return;
    }
    c->state = 0;
    if (ch) c->ch = ch;                                   // 本地已放弃：交给 conn_close 释放通道
    else if (f->kind == 2 && c->local_fd >= 0) socks5_reply(c->local_fd, 0x05);   // 0x05=连接被拒
    for (int i = 0; i < FWD_MAX_CONN; i++) if (f->conns[i] == c) { conn_close(f, i); break; }
}

// libssh2 内部的收包函数（静态库里可链接）。没有活动连接时没人调 channel_read，服务器发来的
// 心跳请求（ClientAliveInterval）等会一直留在 socket 里，select 每轮立刻返回可读 → 空转占满一个核；
// 同时请求得不到回应，服务器到 ClientAliveCountMax 次后会断开空闲隧道。空闲时用它把包收掉（并自动回应）。
extern int _libssh2_transport_read(LIBSSH2_SESSION *session);

static void *forward_pump(void *arg) {
    TermoSSHForward *f = (TermoSSHForward *)arg;
    LIBSSH2_SESSION *session = f->s->session;
    int sock = f->s->sock;
    libssh2_session_set_blocking(session, 0);
    libssh2_keepalive_config(session, 0, 30);
    int ticks = 0;
    int dead = 0;
    int progressed = 0;
    char deadmsg[128] = "连接已断开";

    while (!f->stop) {
        fd_set rfds, wfds;
        FD_ZERO(&rfds); FD_ZERO(&wfds);
        int maxfd = 0;
        #define WATCH(set, fd) do { FD_SET((fd), (set)); if ((fd) > maxfd) maxfd = (fd); } while (0)
        WATCH(&rfds, f->wake[0]);
        if (f->listen_fd >= 0) WATCH(&rfds, f->listen_fd);
        // SSH socket 只在确实要从会话收东西时才监听可读：否则所有连接 s2l 都满时 socket 一直可读，select 立刻返回空转。
        int want_ssh_read = (f->kind == 1) || f->opening != NULL;
        int any = 0;
        for (int i = 0; i < FWD_MAX_CONN; i++) {
            ForwardConn *c = f->conns[i];
            if (!c) continue;
            any = 1;
            if (c->freeing) { want_ssh_read = 1; continue; }   // 等对端 CLOSE 回应
            if (c->state == CS_SOCKS) { WATCH(&rfds, c->local_fd); continue; }
            if (c->state == CS_CONNECT) { WATCH(&wfds, c->local_fd); continue; }
            if (c->state != CS_ACTIVE) continue;
            if (!c->closing && c->s2l_len < FWD_BUF) want_ssh_read = 1;
            if (!c->closing && !c->local_eof && c->l2s_len < FWD_BUF) WATCH(&rfds, c->local_fd);
            if (c->s2l_len > 0) WATCH(&wfds, c->local_fd);
        }
        if (want_ssh_read || !any) WATCH(&rfds, sock);
        if (libssh2_session_block_directions(session) & LIBSSH2_SESSION_BLOCK_OUTBOUND) {
            WATCH(&wfds, sock);                         // 上传：发送缓冲腾出空间就继续写，不用干等 100ms
        }
        #undef WATCH
        // 上一轮有下行数据：libssh2 内部可能还缓着没取完的数据，socket 不一定再可读——这轮不等待
        struct timeval tv = { 0, progressed ? 0 : 100000 };
        progressed = 0;
        select(maxfd + 1, &rfds, &wfds, NULL, &tv);
        if (FD_ISSET(f->wake[0], &rfds)) { char d[64]; while (read(f->wake[0], d, sizeof(d)) > 0) {} }
        if (!any && f->kind != 1 && FD_ISSET(sock, &rfds)) {
            int rc;
            while ((rc = _libssh2_transport_read(session)) > 0) {}
            if (rc < 0 && rc != LIBSSH2_ERROR_EAGAIN) { dead = 1; break; }
        }
        long now = termo_now_ms();

        // -L/-D：接受新本地连接（-L 直接排队开通道，-D 先走 SOCKS5 握手）
        if (f->listen_fd >= 0 && FD_ISSET(f->listen_fd, &rfds)) {
            for (;;) {
                int cfd = accept(f->listen_fd, NULL, NULL);
                if (cfd < 0) break;
                prep_local_fd(cfd);
                ForwardConn *c = fwd_new_conn(f, cfd, f->kind == 2 ? CS_SOCKS : CS_OPEN);
                if (!c) { close(cfd); continue; }        // 连接数已满
                if (c->state == CS_OPEN) {
                    snprintf(c->dhost, sizeof(c->dhost), "%s", f->dest_host);
                    c->dport = f->dest_port;
                    c->seq = ++f->next_seq;
                }
            }
        }

        // -R：接受服务器转回的连接，非阻塞连本地目标
        if (f->kind == 1 && f->rlistener) {
            for (;;) {
                LIBSSH2_CHANNEL *ch = libssh2_channel_forward_accept(f->rlistener);
                if (!ch) break;                         // 无更多（EAGAIN）
                ForwardConn *c = fwd_new_conn(f, -1, CS_CONNECT);
                if (!c) {
                    // 连接数已满：挂不上就只能直接释放（极少见；EAGAIN 时通道随会话关闭回收）
                    libssh2_channel_free(ch);
                    continue;
                }
                c->ch = ch;
                c->naddr = resolve_local_target(f->dest_host, f->dest_port, c->addrs, c->addrlens, 4);
                int r = start_local_connect(c);
                if (r == 1) c->state = CS_ACTIVE;
                else if (r < 0) { for (int i = 0; i < FWD_MAX_CONN; i++) if (f->conns[i] == c) { conn_close(f, i); break; } }
            }
        }

        for (int i = 0; i < FWD_MAX_CONN; i++) {
            ForwardConn *c = f->conns[i];
            if (!c) continue;
            if (c->freeing) { conn_close(f, i); continue; }
            switch (c->state) {
            case CS_SOCKS: {
                int r = FD_ISSET(c->local_fd, &rfds) ? socks5_step(c) : 0;
                if (r < 0 || (r == 0 && now - c->since_ms > FWD_SETUP_TIMEOUT_MS)) { conn_close(f, i); break; }
                if (r == 1) { c->state = CS_OPEN; c->since_ms = now; c->seq = ++f->next_seq; }
                break;
            }
            case CS_CONNECT: {
                int failed = 0;
                if (FD_ISSET(c->local_fd, &wfds)) {
                    int soerr = 0; socklen_t l = sizeof(soerr);
                    getsockopt(c->local_fd, SOL_SOCKET, SO_ERROR, &soerr, &l);
                    if (soerr == 0) c->state = CS_ACTIVE; else failed = 1;
                } else if (now - c->since_ms > FWD_SETUP_TIMEOUT_MS) {
                    failed = 1;
                }
                if (failed) {                           // 这个地址不通：换下一个候选地址
                    close(c->local_fd); c->local_fd = -1;
                    c->addr_idx++;
                    int r = start_local_connect(c);
                    if (r == 1) c->state = CS_ACTIVE;
                    else if (r < 0) conn_close(f, i);
                }
                break;
            }
            case CS_ACTIVE:
                if (conn_pump(c, session, sock, &progressed) < 0) conn_close(f, i);
                break;
            case CS_OPEN:
                // 排队中（还没轮到开通道，尚无任何 libssh2 状态）：客户端已断开或排队太久就直接放弃，
                // 免得黑洞目标卡住队头时，后面的连接一直占着名额、最后还要对已离开的客户端逐个开通道。
                if (c != f->opening) {
                    char b;
                    ssize_t pk = recv(c->local_fd, &b, 1, MSG_PEEK);
                    int gone = pk == 0 || (pk < 0 && errno != EAGAIN && errno != EWOULDBLOCK);
                    if (gone || now - c->since_ms > FWD_SETUP_TIMEOUT_MS) {
                        if (!gone && f->kind == 2) socks5_reply(c->local_fd, 0x04);
                        conn_close(f, i);
                    }
                }
                break;
            default:
                break;
            }
        }
        advance_open(f, session, now);

        // 周期 keepalive，借此探测会话是否已断。有连接挂着半发包或正在开通道时跳过：keepalive 用栈上缓冲发包，
        // 它若只发出一半，就没人能用同一缓冲补发，之后所有写入都会 EAGAIN、隧道卡住。
        if (++ticks >= 100) {                          // ~10s
            int busy = f->opening != NULL || !ssh_can_send_small(session, sock);
            for (int i = 0; i < FWD_MAX_CONN && !busy; i++) if (f->conns[i] && f->conns[i]->write_pending) busy = 1;
            if (!busy) {
                ticks = 0;
                int next = 0;
                int rc = libssh2_keepalive_send(session, &next);
                if (rc < 0 && rc != LIBSSH2_ERROR_EAGAIN) { dead = 1; break; }
            }
        }
    }

    f->opening = NULL;
    for (int i = 0; i < FWD_MAX_CONN; i++) {
        ForwardConn *c = f->conns[i];
        if (!c) continue;
        if (c->local_fd >= 0) close(c->local_fd);
        if (c->ch) libssh2_channel_free(c->ch);        // 会话随后整体关闭，EAGAIN 也无妨
        free(c);
        f->conns[i] = NULL;
    }
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
    out->has_owner = (a->flags & LIBSSH2_SFTP_ATTR_UIDGID) ? 1 : 0;
    out->uid = (unsigned int)a->uid;
    out->gid = (unsigned int)a->gid;
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

int termo_sftp_setstat_owner(TermoSSHSession *s, void *sftp, const char *path, unsigned int uid, unsigned int gid) {
    if (!s || !sftp) return 0xF000;
    LIBSSH2_SFTP_ATTRIBUTES a;
    memset(&a, 0, sizeof(a));
    a.flags = LIBSSH2_SFTP_ATTR_UIDGID;
    a.uid = uid; a.gid = gid;
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

// 只在位置真的不对时才 seek：seek 会清空 libssh2 的预读队列，顺序读每块都 seek 等于每块一个往返（高延迟下吞吐极低）。
static void sftp_seek_if_needed(LIBSSH2_SFTP_HANDLE *h, unsigned long long offset) {
    if (libssh2_sftp_tell64(h) != offset) libssh2_sftp_seek64(h, offset);
}

long termo_sftp_read(void *handle, unsigned long long offset, char *buf, int len) {
    if (!handle || !buf || len <= 0) return -1;
    sftp_seek_if_needed((LIBSSH2_SFTP_HANDLE *)handle, offset);
    ssize_t n = libssh2_sftp_read((LIBSSH2_SFTP_HANDLE *)handle, buf, (size_t)len);
    return (long)n;   // >0 字节 / 0 EOF / <0 错误
}

long termo_sftp_write(void *handle, unsigned long long offset, const char *buf, int len) {
    if (!handle || !buf || len < 0) return -1;
    sftp_seek_if_needed((LIBSSH2_SFTP_HANDLE *)handle, offset);
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

