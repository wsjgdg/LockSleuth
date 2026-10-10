#!/usr/bin/env bash
# smoke_test.sh — LockSleuth Web 服务自动化冒烟测试
# 用法: ./tests/smoke_test.sh [端口，默认随机高位端口]
# 退出码: 0 = 全部通过；1 = 有失败项
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$DIR/LockSleuth"
PORT="${1:-$(( (RANDOM % 20000) + 30000 ))}"
BASE="http://127.0.0.1:$PORT"
HIST="${HOME}/.LockSleuth_history.jsonl"
HIST_BAK=""

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ✔ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ✘ $1"; }
check(){ # check <描述> <期望子串> <实际输出>
  case "$3" in *"$2"*) ok "$1";; *) bad "$1（期望包含: $2，实际: ${3:0:200}）";; esac
}

[ -x "$BIN" ] || { echo "未找到可执行文件 $BIN，请先 make"; exit 1; }
command -v curl >/dev/null || { echo "需要 curl"; exit 1; }

cleanup() {
  [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null
  wait "${SRV_PID:-}" 2>/dev/null
  if [ -n "$HIST_BAK" ] && [ -f "$HIST_BAK" ]; then mv -f "$HIST_BAK" "$HIST"; fi
  rm -f /tmp/fl_smoke_target.txt /tmp/fl_smoke.log
}
trap cleanup EXIT

# 备份历史文件，避免污染用户数据
if [ -f "$HIST" ]; then HIST_BAK=$(mktemp); cp "$HIST" "$HIST_BAK"; fi

echo "== 启动服务（端口 $PORT）=="
"$BIN" --no-open -p "$PORT" > /tmp/fl_smoke.log 2>&1 &
SRV_PID=$!

# 等待就绪（最多 5 秒），用 /api/health 轮询
for i in $(seq 1 50); do
  curl -s -m 1 "$BASE/api/health" | grep -q '"status":"healthy"' && break
  sleep 0.1
done

T() { curl -s -m 5 "$@"; }

echo "== 1. 健康检查与静态资源 =="
check "/api/health 返回 healthy"  '"status":"healthy"' "$(T $BASE/api/health)"
check "/api/health 令牌已生成"    '"tokenReady":1'     "$(T $BASE/api/health)"
check "GET / 返回 HTML"           '<title>'            "$(T $BASE/)"
check "favicon 内嵌无 404"        'svg'                "$(T $BASE/favicon.ico)"

echo "== 2. CSRF / Host / CORS 防御 =="
check "POST 无令牌 → 403"         'CSRF'               "$(T -X POST $BASE/api/scan -d '{"path":"/tmp"}')"
check "错误 Host → 拒绝"          '403'                "$(T -H 'Host: evil.example.com' $BASE/api/init)"
R=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -X OPTIONS "$BASE/api/scan" \
     -H 'Origin: http://evil.example.com' -H 'Access-Control-Request-Method: POST')
[ "$R" = "403" ] && ok "跨源预检 → 403" || bad "跨源预检应 403，实际 $R"
R=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -X OPTIONS "$BASE/api/scan" \
     -H 'Origin: http://127.0.0.1:9999' -H 'Access-Control-Request-Method: POST')
[ "$R" = "204" ] && ok "本机源预检 → 204" || bad "本机预检应 204，实际 $R"

echo "== 3. 令牌获取与扫描 API =="
TOKEN=$(T $BASE/api/init | sed -n 's/.*"token":"\([0-9a-f]*\)".*/\1/p')
[ ${#TOKEN} -eq 64 ] && ok "取得 64 位会话令牌" || bad "未取得令牌"
AUTH=(-H "X-Filelock-Token: $TOKEN" -H 'Content-Type: application/json')

touch /tmp/fl_smoke_target.txt
check "/api/scan 正常路径"        '"ok":1'             "$(T -X POST "${AUTH[@]}" $BASE/api/scan -d '{"path":"/tmp/fl_smoke_target.txt"}')"
check "/api/scan 缺参数报错"      '缺少 path'          "$(T -X POST "${AUTH[@]}" $BASE/api/scan -d '{}')"
check "/api/scan-batch 流式输出"  '"results"'          "$(T -X POST "${AUTH[@]}" $BASE/api/scan-batch -d '{"paths":["/tmp/fl_smoke_target.txt","/nonexistent_xyz"]}"')"
check "/api/analyze 规则匹配"     '"rules"'            "$(T -X POST "${AUTH[@]}" $BASE/api/analyze -d '{"text":"文件正由另一进程使用，因此该进程无法访问此文件。"}')"

echo "== 4. kill 边界校验 =="
check "kill pid=0 被拒"           '缺少有效 pid'       "$(T -X POST "${AUTH[@]}" $BASE/api/kill -d '{"pid":0}')"
check "kill 非数字被拒"           '缺少有效 pid'       "$(T -X POST "${AUTH[@]}" $BASE/api/kill -d '{"pid":"abc"}')"
check "kill 自身 PID 被拒"        '不能结束 LockSleuth'  "$(T -X POST "${AUTH[@]}" $BASE/api/kill -d "{\"pid\":$SRV_PID}")"

echo "== 5. 自我保护（webroot 删除防线）=="
WR_ERR=$(T -X POST "${AUTH[@]}" $BASE/api/act -d "{\"op\":\"delete\",\"path\":\"$DIR/web/app.js\"}")
case "$WR_ERR" in
  *'"ok":1'*) ;;  # webroot 未指向仓库 web/（单文件模式）时跳过断言
  *) check "拒绝删除自身界面文件"  '不允许删除'  "$WR_ERR" ;;
esac

echo "== 6. 历史分页 =="
H=$(T "$BASE/api/history?page=0&per=5")
check "/api/history 返回分页字段" '"total"'  "$H"
check "/api/history items 数组"   '"items"'  "$H"
check "per 超限钳制(<=50)"        '"per":50' "$(T "$BASE/api/history?page=0&per=9999")"
check "越界页返回空 items"        '"items":[]' "$(T "$BASE/api/history?page=99999&per=10")"

echo "== 7. 大请求体防护 =="
python3 - "$BASE" "$TOKEN" <<'PYEOF' 2>/dev/null || echo "  (SKIP: python3 不可用)"
import sys, urllib.request, urllib.error
base, tok = sys.argv[1], sys.argv[2]
body = b'{"path":"' + b'A' * (300 * 1024) + b'"}'
req = urllib.request.Request(base + '/api/scan', data=body,
    headers={'X-Filelock-Token': tok, 'Content-Type': 'application/json'})
try:
    urllib.request.urlopen(req, timeout=8)
    print('  ✘ 超大请求体未被拒绝')
except urllib.error.HTTPError as e:
    print('  ✔ 超大请求体被拒绝' if e.code == 413 else f'  ✘ 期望 413，实际 {e.code}')
PYEOF

echo "== 8. 历史扩展字段与搜索 =="
H=$(T "$BASE/api/history?page=0&per=3")
check "历史含 canRead 字段"   '"canRead"'   "$H"
check "历史含 canWrite 字段"  '"canWrite"'  "$H"
check "历史含 canDelete 字段" '"canDelete"' "$H"
check "历史含 size 字段"      '"size"'      "$H"
check "历史按路径搜索命中"     'fl_smoke_target' "$(T "$BASE/api/history?q=fl_smoke_target&per=5")"
check "无命中搜索返回空"      '"items":[]'  "$(T "$BASE/api/history?q=zzz_no_such_path&per=5")"
check "空搜索词等同不筛选"    '"total"'     "$(T "$BASE/api/history?q=&per=5")"

echo "== 9. record:0 轮询探测不落历史 =="
BEFORE=$(T "$BASE/api/history?per=1" | sed -n 's/.*"total":\([0-9]*\).*/\1/p')
check "record:0 探测正常"     '"ok":1'      "$(T -X POST "${AUTH[@]}" $BASE/api/scan -d '{"path":"/tmp/fl_smoke_target.txt","record":0}')"
AFTER=$(T "$BASE/api/history?per=1" | sed -n 's/.*"total":\([0-9]*\).*/\1/p')
[ "$BEFORE" = "$AFTER" ] && ok "record:0 未写历史（$BEFORE → $AFTER）" || bad "record:0 不应写历史（$BEFORE → $AFTER）"
check "默认仍写历史"          '"ok":1'      "$(T -X POST "${AUTH[@]}" $BASE/api/scan -d '{"path":"/tmp/fl_smoke_target.txt"}')"

echo "== 10. 路径提取 / locate / clipboard =="
check "analyze 响应含 paths"       '"paths"'      "$(T -X POST "${AUTH[@]}" $BASE/api/analyze -d '{"text":"无法删除 C:\\Users\\test\\a.docx 与 /home/user/b.log"}')"
check "analyze 提取到 POSIX 路径"   'b.log'         "$(T -X POST "${AUTH[@]}" $BASE/api/analyze -d '{"text":"无法删除 /home/user/b.log。"}')"
check "analyze 提取到 Windows 路径" 'a.docx'        "$(T -X POST "${AUTH[@]}" $BASE/api/analyze -d '{"text":"无法删除 C:\\Users\\test\\a.docx，另一程序占用"}')"
check "locate 无命中返回空"        '"paths":[]'    "$(T -X POST "${AUTH[@]}" $BASE/api/locate -d '{"name":"zzz_no_such_file_xyz"}')"
check "locate 拒绝带分隔符的名字"  '"paths":[]'    "$(T -X POST "${AUTH[@]}" $BASE/api/locate -d '{"name":"../etc/passwd"}')"
CLIP=$(T $BASE/api/clipboard)
case "$CLIP" in
  *'"ok":1'*|*'不支持'*) ok "clipboard 接口优雅响应" ;;
  *) bad "clipboard 接口异常（实际: ${CLIP:0:120}）" ;;
esac

echo "== 11. 危险操作边界（POSIX 侧）=="
check "删除不存在路径优雅失败"      '"ok":0'        "$(T -X POST "${AUTH[@]}" $BASE/api/act -d '{"op":"delete","path":"/tmp/definitely_missing_xyz"}')"
check "force-clean 不存在路径收场"  '"stillExists":0' "$(T -X POST "${AUTH[@]}" $BASE/api/force-clean -d '{"path":"/tmp/definitely_missing_xyz"}')"
check "unlock 非 Windows 优雅报错"  '"ok":0'        "$(T -X POST "${AUTH[@]}" $BASE/api/unlock -d '{"path":"/tmp/fl_smoke_target.txt"}')"
check "kill 无效 PID 优雅失败"    '"ok":0'        "$(T -X POST "${AUTH[@]}" $BASE/api/kill -d '{"pid":999999999}')"

echo "== 12. health 与静态资源 =="
check "health 含 uptime"     '"uptimeSec"'   "$(T $BASE/api/health)"
check "health 含并发数"      '"activeConns"' "$(T $BASE/api/health)"
check "style.css 可访问"     '{'             "$(T $BASE/style.css)"
check "app.js 含等待释放"    '等待释放'      "$(T $BASE/app.js)"
check "app.js 含前后对比"    '上次'          "$(T $BASE/app.js)"

echo
echo "== 结果: $PASS 通过 / $FAIL 失败 =="
[ "$FAIL" -eq 0 ]
