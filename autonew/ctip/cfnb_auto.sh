#!/usr/bin/env bash
# ============================================================
# cfnb 全自动（自包含）：装依赖 → 优选 → 稳定复核 → 推送 GitHub
# 可在全新沙箱直接运行；沙箱仅放行本地代理出网，故用 proxychains。
#
# 环境变量（推送用，至少给 GH_TOKEN）：
#   GH_TOKEN, OWNER(默认snll66), REPO(默认mavita),
#   GH_PATH(默认autonew/ctip/traeip.txt), BRANCH(默认main)
# 可选: CFNB_PROXY(默认http://127.0.0.1:18080), BYTES(默认20MB), ROUNDS(默认3)
# ============================================================
set -uo pipefail

PROXY="${CFNB_PROXY:-http://127.0.0.1:18080}"
PC=/tmp/cfnb_pc.conf
WORK=/workspace/cfnb
GH_OWNER="${OWNER:-snll66}"
GH_REPO="${REPO:-mavita}"
GH_PATH="${GH_PATH:-autonew/ctip/traeip.txt}"
GH_BRANCH="${BRANCH:-main}"
BYTES="${BYTES:-20000000}"
ROUNDS="${ROUNDS:-3}"

# proxychains 要求 "type host port"（空格分隔）；从 http://host:port 拆出 host/port
PROXY_HOSTPORT="${PROXY#*//}"
PROXY_HOST="${PROXY_HOSTPORT%%:*}"
PROXY_PORT="${PROXY_HOSTPORT##*:}"

export http_proxy="$PROXY" https_proxy="$PROXY"
export DEBIAN_FRONTEND=noninteractive

echo "[1/6] 依赖（优先用 /workspace 缓存，避免每次重装）"
# 缓存放在 $WORK 之外：否则第1步的 mkdir 会提前创建 $WORK，导致第2步 git clone 因“目录非空”失败
CACHE="${CFNB_CACHE:-/workspace/.cfnb-cache}"
PC_BIN=/usr/bin/proxychains4
PC_LIB=/usr/lib/x86_64-linux-gnu/libproxychains.so.4
mkdir -p "$CACHE/bin" "$CACHE/lib" "$CACHE/pydeps"

# proxychains4 = 二进制 + 运行时库(libproxychains.so.4)，两者都缓存
if [ ! -x "$PC_BIN" ] || [ ! -f "$PC_LIB" ]; then
  if [ -x "$CACHE/bin/proxychains4" ] && [ -f "$CACHE/lib/libproxychains.so.4" ]; then
    cp "$CACHE/bin/proxychains4" "$PC_BIN" && chmod 755 "$PC_BIN"
    mkdir -p "$(dirname "$PC_LIB")" && cp "$CACHE/lib/libproxychains.so.4" "$PC_LIB" && chmod 644 "$PC_LIB"
    echo "    proxychains4: 从 /workspace 缓存恢复（bin + lib）"
  else
    apt-get update -qq && apt-get install -y -qq proxychains4 libproxychains4 >/dev/null
    cp "$PC_BIN" "$CACHE/bin/proxychains4" && cp "$PC_LIB" "$CACHE/lib/libproxychains.so.4" \
      && echo "    proxychains4: apt 安装并已缓存（bin + lib）"
  fi
else
  echo "    proxychains4: 系统已存在"
fi

# python 包：缓存到 $CACHE/pydeps，命中则跳过 pip 安装
export PYTHONPATH="$CACHE/pydeps${PYTHONPATH:+:$PYTHONPATH}"
if python3 -c 'import requests, aiohttp, brotlicffi' >/dev/null 2>&1; then
  echo "    python 包: 命中缓存"
else
  python3 -m pip install -q --root-user-action=ignore --target "$CACHE/pydeps" requests aiohttp brotlicffi
  echo "    python 包: 已安装并缓存到 $CACHE/pydeps"
fi

echo "[2/6] 获取 cfnb 代码"
if [ -d "$WORK/.git" ]; then
  git -C "$WORK" fetch -q --depth 1 origin && git -C "$WORK" reset -q --hard origin/HEAD || true
else
  # $WORK 若已存在（上次残留/被提前创建），git clone 会因“目录非空”直接失败 → 先清掉再克隆
  rm -rf "$WORK"
  git clone -q --depth 1 https://github.com/xinyitang3/cfnb.git "$WORK" || { echo "    [中止] 克隆 cfnb 失败"; exit 1; }
fi
# 防空保护④：确保代码真的就位（此前的失败就是这里缺 main.py 却继续往下跑）
[ -f "$WORK/main.py" ] || { echo "    [中止] $WORK/main.py 缺失（克隆不完整）"; exit 1; }
cd "$WORK" || exit 1

echo "[3/6] 写 proxychains 配置 + 规整 config + 运行优选"
cat > "$PC" <<EOF
strict_chain
quiet_mode
proxy_dns
remote_dns_subnet 224
tcp_read_time_out 20000
tcp_connect_time_out 10000
localnet 127.0.0.0/255.0.0.0
[ProxyList]
http ${PROXY_HOST} ${PROXY_PORT}
EOF
python3 - <<'PY'
import json
c = json.load(open("config.json", encoding="utf-8"))
c.update({"CF_ENABLED": False, "ENABLE_WXPUSHER": False, "GITHUB_SYNC_MAX_RETRIES": 0,
          "MAX_WORKERS": 64, "BANDWIDTH_CANDIDATES": 100, "GLOBAL_TOP_N": 30,
          "BANDWIDTH_SIZE_MB": 20.0, "BANDWIDTH_TIMEOUT": 20, "BANDWIDTH_WORKERS": 1})
json.dump(c, open("config.json", "w", encoding="utf-8"), indent=4, ensure_ascii=False)
PY
LOG="$WORK/run.log"
proxychains4 -f "$PC" python3 main.py >"$LOG" 2>&1
RC=$?
echo "    main.py 退出码=$RC（完整日志：$LOG）"
# 只回显关键几行，避免上万行进度刷屏（省 token）
grep -aE '可用性检测通过|HTTP检测通过|结果已保存|Cloudflare DNS|Traceback|rror' "$LOG" | tail -6
# 防空保护①：main.py 失败或 ip.txt 为空 → 立即中止，绝不继续（否则会推空文件）
if [ "$RC" -ne 0 ] || [ ! -s ip.txt ]; then
  echo "    [中止] main.py 失败(rc=$RC) 或 ip.txt 为空，跳过推送，避免把远端覆盖成空文件"
  exit 1
fi

echo "[4/6] 稳定复核（串行 ${ROUNDS} 轮 × $((BYTES/1000000))MB，按最低速排序 → stable.txt）"
: > /tmp/cfnb_stable_raw.txt
while IFS= read -r node; do
  [ -z "$node" ] && continue; case "$node" in \#*) continue ;; esac
  ip="${node%%#*}"; ip="${ip%:*}"
  vals=""
  for r in $(seq 1 "$ROUNDS"); do
    s=$(proxychains4 -q -f "$PC" curl -s -o /dev/null -w '%{speed_download}' --max-time 20 \
        --noproxy '*' --http2 --resolve "speed.cloudflare.com:443:${ip}" \
        "https://speed.cloudflare.com/__down?bytes=${BYTES}" 2>/dev/null || true)
    vals="$vals ${s:-0}"
  done
  awk -v n="$node" -v v="$vals" 'BEGIN{ k=split(v,a," "); mn=1e18; for(i=1;i<=k;i++){x=a[i]*8/1e6; if(x<mn)mn=x} printf "%s\t%.2f\n", n, mn }' >> /tmp/cfnb_stable_raw.txt
done < ip.txt

: > stable.txt
sort -t$'\t' -k2 -nr /tmp/cfnb_stable_raw.txt | while IFS=$'\t' read -r node mn; do
  awk -v m="$mn" 'BEGIN{exit !(m<1)}' && continue
  echo "$node" >> stable.txt
done
echo "    稳定节点数：$(grep -c . stable.txt)"

# 防空保护②：stable.txt 节点数过少 → 中止，绝不推送空文件
SL=$(grep -c . stable.txt || true)
if [ "${SL:-0}" -lt 3 ]; then
  echo "[5/6] [中止] 稳定节点仅 ${SL:-0} 个，跳过推送（避免把远端覆盖成空文件）"
  exit 1
fi
echo "[5/6] 推送 stable.txt → ${GH_OWNER}/${GH_REPO}:${GH_PATH}"
if [ -z "${GH_TOKEN:-}" ]; then echo "    缺少 GH_TOKEN，跳过推送"; else
python3 - <<PY
import base64, json, os, requests
T = os.environ["GH_TOKEN"]; PX = "$PROXY"
P = {"http": PX, "https": PX}
H = {"Authorization": f"Bearer {T}", "Accept": "application/vnd.github+json"}
api = "https://api.github.com/repos/$GH_OWNER/$GH_REPO/contents/$GH_PATH"
c = open("stable.txt", encoding="utf-8").read()
r = requests.get(api, headers=H, proxies=P, params={"ref": "$GH_BRANCH"}, timeout=30)
payload = {"message": "auto update traeip.txt (cfnb stable list)", "content": base64.b64encode(c.encode()).decode(), "branch": "$GH_BRANCH"}
if r.status_code == 200:
    old = base64.b64decode(r.json().get("content") or "").decode("utf-8", "ignore")
    if old == c:
        print("    SKIP 内容与远端一致，跳过本次提交")
        raise SystemExit(0)
    payload["sha"] = r.json()["sha"]
r2 = requests.put(api, headers=H, proxies=P, json=payload, timeout=30)
if r2.status_code in (200, 201):
    print("    PUT OK", r2.json().get("commit", {}).get("html_url"))
else:
    print("    PUT FAIL", r2.status_code, r2.text[:300])
PY
fi

echo "[6/6] 完成。stable 节点数：$(grep -c . stable.txt)（完整列表：$WORK/stable.txt）"
head -3 stable.txt | sed 's/^/    /'
