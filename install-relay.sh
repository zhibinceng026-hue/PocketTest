#!/usr/bin/env bash
set -euo pipefail
test "$(id -u)" = 0 || { echo '请以 root 运行此一次性服务器升级脚本'; exit 1; }
base=$(cd "$(dirname "$0")" && pwd)
test -f "$base/relay.mjs"
config=/etc/agent-control/Caddyfile
caddy=/opt/agent-control/caddy
test -f "$config" && test -x "$caddy" || { echo '未找到现有 Agent Control HTTPS 服务；未修改配置'; exit 1; }
mkdir -p /opt/agent-control/relay
node=$(command -v node || true)
if [ -z "$node" ] || ! "$node" -e 'process.exit(Number(process.versions.node.split(".")[0])>=22?0:1)'; then
  test "$(uname -m)" = x86_64 || { echo '此安装包仅适用于 x86_64'; exit 1; }
  temporary=$(mktemp -d)
  trap 'rm -rf "$temporary"' EXIT
  curl --fail --silent --show-error --location --max-time 60 https://nodejs.org/dist/latest-v24.x/SHASUMS256.txt -o "$temporary/checksums"
  archive=$(awk '$2 ~ /^node-v24\.[0-9]+\.[0-9]+-linux-x64\.tar\.xz$/ {print $2; exit}' "$temporary/checksums")
  test -n "$archive"
  curl --fail --silent --show-error --location --max-time 180 "https://nodejs.org/dist/latest-v24.x/$archive" -o "$temporary/$archive"
  (cd "$temporary" && awk -v name="$archive" '$2==name' checksums | sha256sum --check -)
  mkdir -p /opt/agent-control/relay/node
  tar -xJf "$temporary/$archive" --strip-components=1 -C /opt/agent-control/relay/node
  node=/opt/agent-control/relay/node/bin/node
fi
id agentcontrol-relay >/dev/null 2>&1 || useradd --system --home-dir /var/lib/agent-control-relay --shell /usr/sbin/nologin agentcontrol-relay
install -d -m 700 -o agentcontrol-relay -g agentcontrol-relay /var/lib/agent-control-relay
install -m 644 "$base/relay.mjs" /opt/agent-control/relay/relay.mjs
cat >/etc/systemd/system/agent-control-relay.service <<EOF
[Unit]
Description=Agent Control device enrollment and independent relay
After=network-online.target
Wants=network-online.target
[Service]
User=agentcontrol-relay
Group=agentcontrol-relay
Environment=AC_RELAY_HOME=/var/lib/agent-control-relay
Environment=PORT=48723
ExecStart=$node /opt/agent-control/relay/relay.mjs
Restart=on-failure
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/agent-control-relay
[Install]
WantedBy=multi-user.target
EOF
python3 - "$config" <<'PY'
import pathlib,re,sys,datetime
p=pathlib.Path(sys.argv[1]);s=p.read_text()
if '# Agent Control independent relay' not in s:
    pattern=r'(?m)^([^\n{}]*47\.117\.135\.235[^\n{}]*\{)\s*$'
    match=re.search(pattern,s) or re.search(r'(?m)^(:443\s*\{)\s*$',s)
    if not match:raise SystemExit('无法识别现有 HTTPS 站点，未修改 Caddy；请人工检查配置')
    p.with_name('Caddyfile.before-relay-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S')).write_text(s)
    routes='\n    # Agent Control independent relay\n    handle /control/* {\n        reverse_proxy 127.0.0.1:48723\n    }\n    handle /d/* {\n        reverse_proxy 127.0.0.1:48723\n    }\n'
    s=s[:match.end()]+routes+s[match.end():]
    p.write_text(s)
PY
"$caddy" fmt --overwrite "$config"
"$caddy" adapt --config "$config" --adapter caddyfile >/dev/null
systemctl daemon-reload
systemctl enable --now agent-control-relay
systemctl restart agent-control-relay
systemctl reload-or-restart agent-control-https
echo '服务器注册服务已启动。下面的连接码 10 分钟内有效，仅使用一次，请在新电脑的 Agent Control 中填写：'
runuser -u agentcontrol-relay -- env AC_RELAY_HOME=/var/lib/agent-control-relay "$node" /opt/agent-control/relay/relay.mjs --create-code
echo '以后生成连接码：'
printf 'runuser -u agentcontrol-relay -- env AC_RELAY_HOME=/var/lib/agent-control-relay %q /opt/agent-control/relay/relay.mjs --create-code\n' "$node"
