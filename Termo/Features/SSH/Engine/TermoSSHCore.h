//  进程内 SSH 引擎的 C 接口（基于 libssh2）。SSH 迁移 J1：先只做链接自检，后续扩展为
//  连接/认证/exec/SFTP/PTY/端口转发的完整引擎，替换现有 spawn /usr/bin/ssh 的实现。
//
//  注：libssh2 是纯 SSH C 库，与 Foundation/CoreFoundation 无类型冲突（不像 FreeRDP/WinPR），
//  故可直接 #include <libssh2.h>，无需 FreeRDP 那种纯 C 隔离 TU。
#ifndef TERMO_SSH_CORE_H
#define TERMO_SSH_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

// ── 持久会话 ────────────────────────────────────────────────────────────────
// 一个会话 = 一条已认证的 libssh2 连接，其上可反复开 channel（exec / 后续 SFTP / PTY / 转发）。
// libssh2 单会话非线程安全：上层须用一个串行队列序列化对同一句柄的所有调用。
typedef struct TermoSSHSession TermoSSHSession;

/// 连接 + 握手 + 认证，成功返回会话句柄，失败返回 NULL 并写 err。key_path 非空走公钥认证。
/// real_known_hosts / session_known_hosts 非空时，在**握手后认证前**校验主机密钥：仅当明确与已知密钥
/// **不匹配**（疑似 MITM）才拒绝（err 以 "HOSTKEY_MISMATCH" 开头）；未知主机/解析失败一律放行（保守，不误拒）。
TermoSSHSession *termo_ssh_open(const char *host, int port,
                                const char *user, const char *password,
                                const char *key_path, const char *key_passphrase,
                                const char *real_known_hosts, const char *session_known_hosts,
                                char *err, int errlen);

// ── 主机密钥扫描（握手即可得，无需认证；替代 ssh-keyscan + ssh-keygen）──────────
/// 仅 TCP+握手就能拿到主机公钥与指纹，并对照 known_hosts 判定。供首次连接验证弹窗。
typedef struct {
    int status;          // 0=已知匹配 1=未知 2=不匹配(疑似 MITM) -1=连接/握手失败
    char sha256[80];     // "SHA256:base64"
    char md5[64];        // "ab:cd:…"
    char line[1024];     // known_hosts 行（"<host|[host]:port> <keytype> <base64key>"），写入信任用
} TermoHostKeyScan;

/// 扫描 host:port 的主机密钥（不认证、不发密码）。结果写 *out。
void termo_ssh_scan_hostkey(const char *host, int port,
                            const char *real_known_hosts, const char *session_known_hosts,
                            TermoHostKeyScan *out);

// ── 分阶段测试连接（替代 spawn ssh -v；由 App 进程发起连接，触发本地网络权限）──────
/// 逐阶段回调：stage 1=解析主机 2=建立 TCP 3=SSH 握手 4=身份验证 5=完成。
/// ok=1 该阶段成功；ok=0 失败（message 写原因，随即停止）。在后台线程调用（阻塞）。
typedef void (*TermoSSHStageCallback)(void *userdata, int stage, int ok, const char *message);
void termo_ssh_test(const char *host, int port, const char *user,
                    const char *password, const char *key_path, const char *key_passphrase,
                    TermoSSHStageCallback on_stage, void *userdata);

/// 主机指纹（握手后即可取）。指向会话内部缓冲，勿 free。
const char *termo_ssh_session_sha256(TermoSSHSession *s);
const char *termo_ssh_session_md5(TermoSSHSession *s);

/// 在会话上 exec 一条命令：stdout 写 out、stderr 写 errout（均截断到各自 cap-1、NUL 结尾），
/// 退出码写 *exit_code。返回 0 成功、-1 通道错误（err 写原因）。
int termo_ssh_exec(TermoSSHSession *s, const char *command,
                   char *out, int out_cap, char *errout, int errout_cap,
                   int *exit_code, char *err, int errlen);

/// exec 带 stdin + 整体超时 + 可取消（替代 spawn ssh 的 RemoteFS.run）。返回二进制安全：
/// stdout 写 out、实际字节数写 *out_len；stderr 写 errout、字节数写 *err_len（均不补 NUL，按长度取用）。
/// 输出超过 cap 时**只截断不死锁**（仍继续抽干远端，避免其写阻塞导致永不 EOF）。退出码写 *exit_code。
/// stdin_bytes 非空时写入子进程标准输入后 send_eof。timeout_ms ≤0 视为 20000。
/// 返回：0=完成、1=超时、2=被取消（termo_ssh_cancel 置标志）、-1=错误（err 写原因）。
int termo_ssh_exec2(TermoSSHSession *s, const char *command,
                    const char *stdin_bytes, int stdin_len,
                    char *out, int out_cap, int *out_len,
                    char *errout, int errout_cap, int *err_len,
                    int *exit_code, int timeout_ms, char *err, int errlen);

/// 流式上传 exec（替代 spawn ssh + cat）：exec 命令后，反复调 pull(ud, buf, cap) 取 stdin 数据写入远端。
/// pull 返回：>0=写入的字节数 / 0=数据结束(send_eof 正常收尾) / <0=取消（立即停止，不 send_eof，保留远端半截供续传）。
/// 返回：0=完成 / 1=被 pull 取消 / -1=错误（err 写原因）。*exit_code 写远端退出码。在后台线程调用（阻塞）。
typedef int (*TermoSSHPullCallback)(void *userdata, char *buf, int cap);
int termo_ssh_exec_upload(TermoSSHSession *s, const char *command,
                          TermoSSHPullCallback pull, void *userdata,
                          int *exit_code, char *err, int errlen);

/// 流式 exec：exec 一条长跑命令，stdout 数据增量回调 on_data（直到 EOF/错误/被取消）。
/// 阻塞调用线程直到结束；用 termo_ssh_cancel 从另一线程打断（仅置标志，线程安全）。
/// 返回 0=正常结束/被取消、-1=错误（err 写原因）。
typedef void (*TermoSSHDataCallback)(void *userdata, const char *bytes, int len);
int termo_ssh_exec_stream(TermoSSHSession *s, const char *command,
                          TermoSSHDataCallback on_data, void *userdata,
                          char *err, int errlen);

/// 请求中止当前流式读取（置标志，可从任意线程调用）。
void termo_ssh_cancel(TermoSSHSession *s);

/// 断开并释放会话。
void termo_ssh_close(TermoSSHSession *s);

// ── 交互式 shell（终端 PTY，替代 spawn /usr/bin/ssh + LocalProcessTerminalView 子进程）──────
// 在一条 dedicated 会话上开 PTY + shell，由一个独立 pump 线程做全部 libssh2 读/写/resize（杜绝并发），
// 用自管道唤醒以零延迟响应输入。on_data 在 pump 线程回调（增量 stdout）；on_closed 结束时回调一次
// （exit_code：远端 shell 退出码；掉线=255，与 ssh 对齐以触发上层重连）。
typedef struct TermoSSHShell TermoSSHShell;
typedef void (*TermoSSHClosedCallback)(void *userdata, int exit_code);

/// 开 PTY(xterm-256color, cols×rows) + shell 并启动 pump 线程。成功返回句柄，失败 NULL 并写 err。
TermoSSHShell *termo_ssh_shell_open(TermoSSHSession *s, int cols, int rows,
                                    TermoSSHDataCallback on_data,
                                    TermoSSHClosedCallback on_closed, void *userdata,
                                    char *err, int errlen);
/// 写入远端 PTY（线程安全：入队 + 唤醒 pump，立即返回）。返回入队字节或 -1。
long termo_ssh_shell_write(TermoSSHShell *sh, const char *buf, int len);
/// 通知 PTY 尺寸变化（线程安全）。
int  termo_ssh_shell_resize(TermoSSHShell *sh, int cols, int rows);
/// 停 pump 线程 + 关闭/释放通道与句柄（幂等由调用方保证；不关底层会话，调用方另行 close）。
void termo_ssh_shell_close(TermoSSHShell *sh);

// ── 端口转发（-L / -R / -D，替代 spawn ssh -N）────────────────────────────────
// 每条隧道一条 dedicated 会话 + 一个 pump 线程：数据转发全非阻塞多路复用（一个会话上并发多 channel），
// 建立阶段（开 direct_tcpip / SOCKS5 协商 / -R 本地连接）短暂阻塞以控制复杂度。
typedef struct TermoSSHForward TermoSSHForward;
/// 隧道异步状态：ok=0 表示连接断开/致命错误（message 写原因），上层据此重连/标记失败。
typedef void (*TermoSSHForwardStateCallback)(void *userdata, int ok, const char *message);

/// 开启端口转发。kind：0=本地(-L) 1=远程(-R) 2=动态 SOCKS5(-D)。
/// -L/-D：在 bind_addr:listen_port 开本地监听（dest_* 为 -L 的目标；-D 忽略 dest）。
/// -R：在服务器 bind_addr:listen_port 开远端监听，进来的连接转回本机的 dest_host:dest_port。
/// 监听建立失败（端口占用等）立即返回 NULL 并写 err（含「本地端口已被占用」/「转发请求被拒绝」）。
TermoSSHForward *termo_ssh_forward_open(TermoSSHSession *s, int kind,
                                        const char *bind_addr, int listen_port,
                                        const char *dest_host, int dest_port,
                                        TermoSSHForwardStateCallback on_state, void *userdata,
                                        char *err, int errlen);
/// 停 pump 线程 + 关闭监听与所有活动连接（不关底层会话，调用方另行 close）。
void termo_ssh_forward_close(TermoSSHForward *f);

// ── SFTP 子系统（libssh2_sftp_*，替代手写 FXP）──────────────────────────────
// 全部非线程安全：上层须在该会话的同一串行队列上调用（SFTP 用独占 dedicated 会话）。
// 返回 int 的函数约定：0=成功；>0 且 <0xF000 = SFTP 状态码(LIBSSH2_FX_*，如 2=无此文件)；
// ≥0xF000 = 传输/底层错误（连接断、协议错）。open/opendir/init 失败返回 NULL（用 last_errno 取因）。

/// SFTP 文件属性（仅本端用到的字段；has_* 标识该字段是否有效）。
typedef struct {
    int has_size, has_perm, has_mtime;
    unsigned long long size;
    unsigned int permissions;
    unsigned int mtime;
} TermoSFTPAttrs;

/// 在已认证会话上初始化 SFTP 子系统，返回 LIBSSH2_SFTP*（void*）或 NULL。
void *termo_sftp_init(TermoSSHSession *s);
/// 关闭 SFTP 子系统（不关底层会话）。
void  termo_sftp_shutdown(void *sftp);
/// 取最近一次 SFTP 操作的协议状态码（LIBSSH2_FX_*）。
int   termo_sftp_last_errno(void *sftp);

/// stat（follow=1 跟随符号链接 / 0 = lstat）。
int   termo_sftp_stat(TermoSSHSession *s, void *sftp, const char *path, int follow, TermoSFTPAttrs *out);
/// 设权限位（mode & 07777）。
int   termo_sftp_setstat_perm(TermoSSHSession *s, void *sftp, const char *path, unsigned int mode);
int   termo_sftp_mkdir(TermoSSHSession *s, void *sftp, const char *path);
int   termo_sftp_rmdir(TermoSSHSession *s, void *sftp, const char *path);
int   termo_sftp_unlink(TermoSSHSession *s, void *sftp, const char *path);
/// 重命名；overwrite=1 → OVERWRITE|ATOMIC|NATIVE（posix-rename 原子覆盖）；=0 → 不覆盖。
int   termo_sftp_rename(TermoSSHSession *s, void *sftp, const char *from, const char *to, int overwrite);
/// 解析为绝对路径，写入 out（截断到 out_cap-1，NUL 结尾）。
int   termo_sftp_realpath(TermoSSHSession *s, void *sftp, const char *path, char *out, int out_cap);

/// 打开文件，pflags 直接透传 LIBSSH2_FXF_*（与 SFTPFlag 同值）。返回句柄（void*）或 NULL。
void *termo_sftp_open(TermoSSHSession *s, void *sftp, const char *path, unsigned int pflags);
/// 打开目录。返回句柄或 NULL。
void *termo_sftp_opendir(TermoSSHSession *s, void *sftp, const char *path);
/// 句柄 fstat。
int   termo_sftp_fstat(void *handle, TermoSFTPAttrs *out);
/// 从 offset 读一块（内部 seek64+read）：返回字节数 / 0=EOF / 负=错误。
long  termo_sftp_read(void *handle, unsigned long long offset, char *buf, int len);
/// 从 offset 写整块（内部 seek64 + 循环写完）：返回已写字节 / 负=错误。
long  termo_sftp_write(void *handle, unsigned long long offset, const char *buf, int len);
/// 读一个目录项：name 写 name_buf（NUL 结尾）。返回名字长度 / 0=EOF / 负=错误。
int   termo_sftp_readdir(void *handle, char *name_buf, int name_cap, TermoSFTPAttrs *out);
/// 关闭文件/目录句柄。
void  termo_sftp_close(void *handle);

// ── 密钥生成 / 导入（OpenSSL + 手写 OpenSSH 格式，替代 ssh-keygen）──────────────
/// 生成密钥对。type：0=ed25519 1=rsa(4096)。out_priv=私钥文本、out_pub=公钥行、out_fp="SHA256:…"。
/// passphrase 非空则加密私钥（RSA 经 OpenSSL PKCS#8；ed25519 经 OpenSSH + bcrypt）。返回 0/-1(+err)。
int termo_key_generate(int type, const char *comment, const char *passphrase,
                       char *out_priv, int priv_cap, char *out_pub, int pub_cap,
                       char *out_fp, int fp_cap, char *err, int errlen);
/// 从私钥文件派生公钥行（无注释）。返回 0=成功 / 1=已加密无法派生(PEM) / -1=错误。
/// *out_type 0=ed25519/1=rsa；*out_encrypted 1=私钥加密（OpenSSH 格式即使加密也能派生公钥，故 rc=0 但 encrypted=1）。
int termo_key_pubkey_from_private(const char *priv_path, const char *passphrase,
                                  char *out_pub, int pub_cap, int *out_type, int *out_encrypted);
/// 由公钥行算 "SHA256:…" 指纹。返回 0/-1。
int termo_key_fingerprint(const char *pub_line, char *out_fp, int fp_cap);

#ifdef __cplusplus
}
#endif

#endif /* TERMO_SSH_CORE_H */
