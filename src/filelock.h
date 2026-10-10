/*
 * filelock — 文件占用诊断器（图形界面版）
 * 公共头文件
 */
#ifndef FILELOCK_H
#define FILELOCK_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/types.h>

#ifdef _WIN32
#  ifndef _WIN32_WINNT
#    define _WIN32_WINNT 0x0601
#  endif
#  define WIN32_LEAN_AND_MEAN
#  include <windows.h>
#  include <restartmanager.h>
/* MSVC 缺失的 POSIX 兼容补齐（MinGW/GCC 已自带，#ifndef 防重定义） */
#  ifndef strncasecmp
#    define strncasecmp _strnicmp
#  endif
#  ifndef strcasecmp
#    define strcasecmp _stricmp
#  endif
#  ifndef S_ISDIR
#    define S_ISDIR(m) (((m) & _S_IFMT) == _S_IFDIR)
#  endif
#  ifndef S_ISREG
#    define S_ISREG(m) (((m) & _S_IFMT) == _S_IFREG)
#  endif
#  ifndef S_ISLNK
#    define S_ISLNK(m) (0)
#  endif
#else
#  include <unistd.h>
#  include <fcntl.h>
#  include <signal.h>
#  include <dirent.h>
#  include <strings.h>
#  if defined(__APPLE__)
#    include <sys/param.h>
#    include <sys/mount.h>
#  elif defined(__linux__)
#    include <sys/vfs.h>
#    include <sys/mount.h>
#    include <sys/ioctl.h>
#    include <linux/fs.h>
#  endif
#endif

#ifdef __GNUC__
#  define UNUSED_FN __attribute__((unused))
#else
#  define UNUSED_FN
#endif

/* BSD/macOS 文件标志回退值 */
#ifndef SF_IMMUTABLE
#  define SF_IMMUTABLE 0x00020000
#endif
#ifndef UF_IMMUTABLE
#  define UF_IMMUTABLE 0x00000002
#endif
#ifndef SF_APPEND
#  define SF_APPEND 0x00040000
#endif
#ifndef MNT_RDONLY
#  define MNT_RDONLY 0x00000001
#endif

#define MAX_ITEMS   32
#define ITEM_LEN    512
#define MAX_LOCKERS 32

typedef struct {
    long pid;
    long ppid;        /* 父进程 ID（0/未知时前端按扁平列表展示） */
    char name[128];
    char detail[256];
} Locker;

typedef struct {
    char reasons[MAX_ITEMS][ITEM_LEN];
    int  nreasons;
    char fixes[MAX_ITEMS][ITEM_LEN];
    int  nfixes;
    Locker lockers[MAX_LOCKERS];
    int  nlockers;

    int  exists;
    int  is_dir;
    int  is_link;
    int  can_read;
    int  can_write;
    int  can_delete;
    int  restricted;
    long long size;
} Report;

/* 粘贴提示分析结果 */
typedef struct {
    char cause[ITEM_LEN];
    char fixes[8][ITEM_LEN];
    int  nfixes;
    int  hits;          /* 命中关键词数量 */
    int  platform;      /* 0=通用 1=Windows 2=macOS */
} RuleHit;

/* 检测历史条目（三态/大小随历史留存，供“上次 vs 现在”对比；旧记录缺字段按 0 解析） */
typedef struct {
    char path[ITEM_LEN];
    char conclusion[ITEM_LEN];
    int  exists;
    int  nlockers;
    int  restricted;
    int  can_read;
    int  can_write;
    int  can_delete;
    long long size;
    long long ts;
} HistoryItem;

/* 句柄解锁命中记录 */
typedef struct {
    long pid;
    char name[128];
    int  count;      /* 关闭的句柄数 */
} UnlockHit;

/* ---- diagnose.c ---- */
int  diagnose_path(const char *path, Report *r, int deep);   /* 0=执行成功(不代表无占用) */
int  kill_locker(const Locker *L);
void print_report(const char *path, const Report *r);        /* 命令行模式输出 */
void report_add_reason(Report *r, const char *fmt, ...);
void report_add_fix(Report *r, const char *fmt, ...);

/* ---- rules.c ---- */
int  analyze_text(const char *text, RuleHit *hits, int max);  /* 返回命中规则数 */
int  extract_paths(const char *text, char out[][ITEM_LEN], int max);

/* ---- browse.c ---- */
/* type: "file" 或 "dir"；成功返回 0 并写入 path；失败返回 -1 并写入 err */
int  native_browse(const char *type, char *path, size_t np, char *err, size_t ne);

/* ---- clipboard.c ---- */
/* 读取系统剪贴板文本：1=有内容 0=空 -1=不支持 */
int  clipboard_read(char *buf, size_t n);

/* ---- locate.c ---- */
/* 按文件/文件夹名在常见目录中查找真实路径，返回找到的数量 */
int  locate_path(const char *name, char out[][ITEM_LEN], int max);

/* ---- history.c ---- */
int  history_add(const char *path, const Report *r);
int  history_list(HistoryItem *out, int max);   /* 新→旧，返回条数 */
/* 分页读取：page 从 0 开始，每页 per_page 条（新→旧）；out_cap 为数组容量。
 * search 可选：按路径/结论大小写不敏感子串过滤（NULL/空串=不过滤）。
 * total_out 可选输出过滤后总条数（用于前端计算页数）。返回本页条数。 */
int  history_page(HistoryItem *out, int out_cap, int page, int per_page,
                  const char *search, long long *total_out);
int  history_clear(void);

/* ---- close_handle.c ---- */
/* Windows：不杀进程，直接关闭占用句柄；成功返回 0；closed 为关闭的句柄数 */
int  close_file_handles(const char *path, int is_dir, int *closed,
                        UnlockHit *hits, int maxhits, char *err, size_t ne);

/* ---- httpd.c（供 CLI/HTTP 共用的删除辅助）---- */
/* 安全删除：先解除只读属性再删；目录非空/仍被占用时自动恢复原只读状态。
 * 返回 0=成功；-1=失败且已恢复只读；-2=失败但无法恢复只读（需提示用户）。 */
int  safe_remove_path(const char *path, int is_dir, char *errbuf, size_t n);

/* ---- menu.c ---- */
/* 右键菜单集成（Windows 注册表）：1=成功 0=失败 */
int  install_context_menu(char *err, size_t ne);
int  uninstall_context_menu(char *err, size_t ne);

/* ---- jsonutil.c ---- */
void json_escape(const char *in, char *out, size_t n);
int  json_get_string(const char *json, const char *key, char *out, size_t n);
int  json_get_int(const char *json, const char *key, int def);
int  json_array_strings(const char *json, const char *key, char out[][ITEM_LEN], int max);

/* ---- httpd.c ---- */
/* CSRF 会话令牌：服务启动前生成；危险 API 必须携带 X-Filelock-Token 请求头 */
void httpd_init_token(void);
const char *httpd_get_token(void);
int  httpd_serve(const char *webroot, int *port, void (*on_ready)(int port));
/* 阻塞式服务循环；port 传入期望端口，传出实际端口；on_ready 在服务就绪后回调 */
void httpd_open_browser(int port);
void httpd_open_url(const char *url);   /* 用系统默认浏览器打开任意 URL */

/* ---- open.c ---- */
/* 右键菜单入口：后台拉起服务（已在跑则复用）并在浏览器打开界面定位到路径。
 * path 可为 NULL。成功返回 0，失败返回 -1 并写 err。 */
int  open_ui(const char *path, char *err, size_t ne);

/* ---- autostart.c ---- */
/* 开机自启注册（当前用户，免管理员）：1=成功 0=失败 */
int  install_autostart(char *err, size_t ne);
int  uninstall_autostart(char *err, size_t ne);
int  autostart_installed(void);   /* 1=已注册 */

/* ---- tray.c ---- */
/* Windows 托盘常驻（服务跑工作线程，主线程跑消息循环）。
 * 非 Windows 平台返回 -1，由 main 回退普通前台模式。 */
int  tray_serve(const char *webroot, int *port);

#endif /* FILELOCK_H */
