# filelock — 文件占用诊断器
#   make          构建 ./filelock（macOS / Linux）
#   make run      构建并启动图形界面
#   make clean    清理

CC      ?= cc
HOSTCC  ?= cc          # 宿主机编译器（构建 embed_web 等构建期工具，交叉编译时不能用 $(CC)）
CFLAGS  ?= -O2 -Wall -Wextra
# _DEFAULT_SOURCE: 严格模式下显式暴露 nanosleep/strcasestr 等 POSIX 扩展
# （注意：必须写在 CFLAGS ?= 之后，否则 ?= 不生效）
CFLAGS  += -D_DEFAULT_SOURCE
BIN     := filelock
EMBED   := src/web_embedded.h
SRC     := src/main.c src/diagnose.c src/rules.c src/browse.c src/clipboard.c src/locate.c src/history.c src/close_handle.c src/menu.c src/jsonutil.c src/httpd.c src/open.c src/autostart.c src/tray.c

ifeq ($(OS),Windows_NT)
  LDFLAGS := -lws2_32 -lcomdlg32 -lshell32 -lole32 -ladvapi32 -luser32 -lrstrtmgr
  BIN := filelock.exe
else
  UNAME := $(shell uname -s)
  LDFLAGS := -pthread
endif

all: $(BIN)

# 把 web 界面打包进二进制（单文件分发）；此工具在宿主机运行，必须用 HOSTCC
tools/embed_web: tools/embed_web.c
	$(HOSTCC) $(CFLAGS) tools/embed_web.c -o tools/embed_web

$(EMBED): tools/embed_web web/index.html web/app.js web/style.css
	tools/embed_web $(EMBED) EMB_INDEX_HTML web/index.html EMB_APP_JS web/app.js EMB_STYLE_CSS web/style.css

$(BIN): $(SRC) src/filelock.h $(EMBED)
	$(CC) $(CFLAGS) $(SRC) -o $(BIN) $(LDFLAGS)

run: $(BIN)
	./$(BIN)

# 单元测试（verify.sh 的 make test 门禁）
tests/unit_test: tests/unit_test.c src/rules.c src/jsonutil.c src/filelock.h
	$(CC) $(CFLAGS) tests/unit_test.c src/rules.c src/jsonutil.c -o $@

tests/unit_history: tests/unit_history.c src/history.c src/jsonutil.c src/diagnose.c src/filelock.h
	$(CC) $(CFLAGS) tests/unit_history.c src/history.c src/jsonutil.c src/diagnose.c -o $@ $(LDFLAGS)

test: tests/unit_test tests/unit_history
	./tests/unit_test
	@HOME=$$(mktemp -d) ./tests/unit_history

clean:
	rm -f $(BIN) filelock.exe tools/embed_web tools/embed_web.exe tests/unit_test tests/unit_history $(EMBED)

.PHONY: all run test clean
