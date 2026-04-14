#!/bin/bash

# ══════════════════════════════════════════════════════════════════
#  NEXUS XRAY UPDATER — VMess + VLess + Trojan + HTTPUpgrade
#  Update: xray config + nginx xray.conf + haproxy.cfg
# ══════════════════════════════════════════════════════════════════

green="\e[38;5;82m"
red="\e[38;5;196m"
yellow="\e[38;5;226m"
orange="\e[38;5;130m"
blue="\e[38;5;39m"
neutral="\e[0m"

# ─── URL dari nexusv2 ──────────────────────────────────────────────────────
vmess_url="https://raw.githubusercontent.com/nexus-bot-dev/benner/main/configvmess/config.json"
vless_url="https://raw.githubusercontent.com/nexus-bot-dev/benner/main/configvless/config.json"
trojan_url="https://raw.githubusercontent.com/nexus-bot-dev/benner/main/configtrojan/config.json"
haproxy_cfg_url="https://raw.githubusercontent.com/nexus-bot-dev/benner/main/haproxy/haproxy.cfg"
xray_conf_url="https://raw.githubusercontent.com/nexus-bot-dev/benner/main/xray/xray.conf"
# ──────────────────────────────────────────────────────────────────────────

[ "$EUID" -ne 0 ] && { echo -e "${red}Harus root!${neutral}"; exit 1; }

clear
echo -e "${orange}══════════════════════════════════════════${neutral}"
echo -e "   ${green}.::::. NEXUS XRAY UPDATER .::::.${neutral}"
echo -e "${orange}══════════════════════════════════════════${neutral}"
echo -e " ${blue}VMess · VLess · Trojan + HTTPUpgrade${neutral}"
echo -e " ${blue}Nginx xray.conf + HAProxy haproxy.cfg${neutral}"
echo -e "${orange}══════════════════════════════════════════${neutral}"
echo ""

# ─────────────────────────────────────────────────────────────────────────
# 1. BACA UUID AKTIF
# ─────────────────────────────────────────────────────────────────────────
echo -e "${yellow}[1/5] Membaca UUID aktif dari config server...${neutral}"
OLD_UUID=""
for proto in vmess vless trojan; do
    cfg="/etc/xray/${proto}/config.json"
    [ -f "$cfg" ] || continue
    UUID_TMP=$(grep -oP '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$cfg" | head -1)
    if [ -n "$UUID_TMP" ]; then
        OLD_UUID="$UUID_TMP"
        echo -e "    ${green}[ok] UUID dari ${proto}: ${OLD_UUID}${neutral}"
        break
    fi
done
if [ -z "$OLD_UUID" ]; then
    OLD_UUID=$(cat /proc/sys/kernel/random/uuid)
    echo -e "    ${yellow}[new] UUID generate baru: ${OLD_UUID}${neutral}"
fi

# ─────────────────────────────────────────────────────────────────────────
# 2. BACKUP CONFIG LAMA
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${yellow}[2/5] Backup config lama...${neutral}"
BACKUP_DIR="/etc/xray/backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
for proto in vmess vless trojan; do
    [ -f "/etc/xray/${proto}/config.json" ] && \
        cp "/etc/xray/${proto}/config.json" "${BACKUP_DIR}/${proto}_config.json"
done
[ -f /etc/nginx/conf.d/xray.conf ] && cp /etc/nginx/conf.d/xray.conf "${BACKUP_DIR}/xray.conf"
[ -f /etc/haproxy/haproxy.cfg ]    && cp /etc/haproxy/haproxy.cfg    "${BACKUP_DIR}/haproxy.cfg"
echo -e "    ${green}[ok] Backup di: ${BACKUP_DIR}${neutral}"

# ─────────────────────────────────────────────────────────────────────────
# 3. DOWNLOAD & UPDATE XRAY CONFIG (vmess/vless/trojan)
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${yellow}[3/5] Update xray config + inject HTTPUpgrade...${neutral}"

download_json() {
    local url="$1" dest="$2" label="$3"
    mkdir -p "$(dirname "$dest")"
    if wget -q --timeout=30 -O "${dest}.tmp" "$url"; then
        if python3 -c "import json; json.load(open('${dest}.tmp'))" 2>/dev/null; then
            mv "${dest}.tmp" "$dest"
            echo -e "    ${green}[ok] ${label} downloaded${neutral}"
            return 0
        else
            echo -e "    ${red}[err] ${label} JSON invalid!${neutral}"
            rm -f "${dest}.tmp"; return 1
        fi
    else
        echo -e "    ${red}[err] ${label} gagal download${neutral}"
        rm -f "${dest}.tmp"; return 1
    fi
}

download_json "$vmess_url"  "/etc/xray/vmess/config.json"  "VMess config"
download_json "$vless_url"  "/etc/xray/vless/config.json"  "VLess config"
download_json "$trojan_url" "/etc/xray/trojan/config.json" "Trojan config"

# Inject HTTPUpgrade + restore UUID
python3 - <<PYEOF
import json, re

OLD_UUID = "${OLD_UUID}"
configs = [
    ("vmess",  10009, "/vmess-hu"),
    ("vless",  10010, "/vless-hu"),
    ("trojan", 10011, "/trojan-hu"),
]

for proto, port, path in configs:
    cfg_path = f"/etc/xray/{proto}/config.json"
    try:
        with open(cfg_path) as f:
            raw = f.read()
        clean = re.sub(r"#[^\n]*", "", raw)
        data = json.loads(clean)

        # Restore UUID di semua inbound
        for ib in data.get("inbounds", []):
            for c in ib.get("settings", {}).get("clients", []):
                if "id" in c:       c["id"]       = OLD_UUID
                if "password" in c: c["password"] = OLD_UUID

        # Tambah HTTPUpgrade inbound kalau belum ada
        existing_ports = [ib.get("port") for ib in data.get("inbounds", [])]
        if port in existing_ports:
            print(f"    [skip] {proto} HTTPUpgrade port {port} sudah ada")
        else:
            if proto == "vmess":
                cl = {"id": OLD_UUID, "alterId": 0, "email": "default_hu"}
                st = {"clients": [cl]}
            elif proto == "vless":
                cl = {"id": OLD_UUID, "email": "default_hu"}
                st = {"decryption": "none", "clients": [cl]}
            else:
                cl = {"password": OLD_UUID, "email": "default_hu"}
                st = {"clients": [cl], "udp": True}

            data["inbounds"].append({
                "listen": "127.0.0.1",
                "port": port,
                "protocol": proto,
                "settings": st,
                "streamSettings": {
                    "network": "httpupgrade",
                    "httpupgradeSettings": {"path": path, "host": ""}
                },
                "sniffing": {"enabled": True, "destOverride": ["http", "tls"]}
            })
            print(f"    [ok] {proto} HTTPUpgrade port {port} path '{path}' ditambahkan")

        with open(cfg_path, "w") as f:
            json.dump(data, f, indent=2)
        print(f"    [ok] {proto} config saved | UUID: {OLD_UUID}")

    except Exception as e:
        print(f"    [error] {proto}: {e}")
PYEOF

# ─────────────────────────────────────────────────────────────────────────
# 4a. NGINX xray.conf
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${yellow}[4/5] Update nginx xray.conf...${neutral}"

NGINX_CONF="/etc/nginx/conf.d/xray.conf"
if wget -q --timeout=30 -O "${NGINX_CONF}.tmp" "$xray_conf_url"; then
    mv "${NGINX_CONF}.tmp" "$NGINX_CONF"
    echo -e "    ${green}[ok] xray.conf downloaded${neutral}"
else
    echo -e "    ${yellow}[warn] Gagal download xray.conf, pakai existing${neutral}"
fi

python3 - <<'NGINX_PY'
CONF = "/etc/nginx/conf.d/xray.conf"
MARKER = "# nexus-httpupgrade-inject"

HU_BLOCKS = """
    # nexus-httpupgrade-inject
    location /vmess-hu {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10009;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_connect_timeout 60s;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
    location /vless-hu {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10010;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_connect_timeout 60s;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
    location /trojan-hu {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10011;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_connect_timeout 60s;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }"""

try:
    with open(CONF) as f:
        content = f.read()

    if MARKER in content:
        print("    [skip] nginx HTTPUpgrade location sudah ada")
    else:
        # Inject sebelum closing brace terakhir (akhir server block)
        last_brace = content.rfind('\n}')
        if last_brace != -1:
            content = content[:last_brace] + "\n" + HU_BLOCKS + "\n" + content[last_brace:]
            with open(CONF, "w") as f:
                f.write(content)
            print("    [ok] nginx location /vmess-hu /vless-hu /trojan-hu ditambahkan")
        else:
            print("    [warn] Struktur xray.conf tidak dikenali, inject manual diperlukan")
except Exception as e:
    print(f"    [error] nginx inject: {e}")
NGINX_PY

# Validasi nginx
if nginx -t 2>/dev/null; then
    echo -e "    ${green}[ok] nginx config valid${neutral}"
else
    echo -e "    ${red}[err] nginx config invalid! Restore backup...${neutral}"
    [ -f "${BACKUP_DIR}/xray.conf" ] && cp "${BACKUP_DIR}/xray.conf" "$NGINX_CONF"
    nginx -t 2>&1 | head -5
fi

# ─────────────────────────────────────────────────────────────────────────
# 4b. HAPROXY haproxy.cfg
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${yellow}[4b] Update haproxy.cfg...${neutral}"

HAPROXY_CFG="/etc/haproxy/haproxy.cfg"
if wget -q --timeout=30 -O "${HAPROXY_CFG}.tmp" "$haproxy_cfg_url"; then
    mv "${HAPROXY_CFG}.tmp" "$HAPROXY_CFG"
    echo -e "    ${green}[ok] haproxy.cfg downloaded${neutral}"
else
    echo -e "    ${yellow}[warn] Gagal download haproxy.cfg, pakai existing${neutral}"
fi

python3 - <<'HAPROXY_PY'
import re

CFG = "/etc/haproxy/haproxy.cfg"
BACKEND_MARKER = "# nexus-httpupgrade-backend"
ACL_MARKER     = "# nexus-httpupgrade-acl"

HU_BACKENDS = """
#──────────────────────────────────────────
# nexus-httpupgrade-backend
#──────────────────────────────────────────
backend vmess-httpupgrade
    mode http
    timeout connect 60s
    timeout server  3600s
    timeout tunnel  3600s
    server vmess_hu 127.0.0.1:10009 check

backend vless-httpupgrade
    mode http
    timeout connect 60s
    timeout server  3600s
    timeout tunnel  3600s
    server vless_hu 127.0.0.1:10010 check

backend trojan-httpupgrade
    mode http
    timeout connect 60s
    timeout server  3600s
    timeout tunnel  3600s
    server trojan_hu 127.0.0.1:10011 check
"""

HU_ACL = """\
    # nexus-httpupgrade-acl
    acl is_vmess_hu  path_beg /vmess-hu
    acl is_vless_hu  path_beg /vless-hu
    acl is_trojan_hu path_beg /trojan-hu
    use_backend vmess-httpupgrade  if is_vmess_hu
    use_backend vless-httpupgrade  if is_vless_hu
    use_backend trojan-httpupgrade if is_trojan_hu"""

try:
    with open(CFG) as f:
        content = f.read()

    modified = False

    # 1. Tambah backend di akhir file
    if BACKEND_MARKER not in content:
        content = content.rstrip() + "\n" + HU_BACKENDS
        print("    [ok] haproxy HTTPUpgrade backend ditambahkan")
        modified = True
    else:
        print("    [skip] haproxy HTTPUpgrade backend sudah ada")

    # 2. Inject ACL ke frontend/listen yang punya mode http
    #    Cari setiap blok frontend/listen, cek ada "mode http", inject sebelum default_backend
    if ACL_MARKER not in content:
        lines = content.splitlines()
        result = []
        i = 0
        injected = False
        while i < len(lines):
            line = lines[i]
            stripped = line.strip()

            # Deteksi blok frontend atau listen
            if re.match(r'^(frontend|listen)\s+', stripped):
                # Kumpulkan seluruh blok
                block_start = i
                block_lines = [line]
                i += 1
                while i < len(lines) and not re.match(r'^(frontend|listen|backend|global|defaults)\s+', lines[i].strip()):
                    block_lines.append(lines[i])
                    i += 1
                block_text = '\n'.join(block_lines)

                # Cek apakah blok ini mode http
                if 'mode http' in block_text and not injected:
                    # Inject sebelum baris default_backend
                    new_block = []
                    for bl in block_lines:
                        if bl.strip().startswith('default_backend') and not injected:
                            new_block.append(HU_ACL)
                            injected = True
                        new_block.append(bl)
                    # Kalau tidak ada default_backend, inject di akhir blok
                    if not injected:
                        new_block.append(HU_ACL)
                        injected = True
                    result.extend(new_block)
                else:
                    result.extend(block_lines)
                continue  # i sudah di-advance di dalam loop

            result.append(line)
            i += 1

        if injected:
            content = '\n'.join(result)
            print("    [ok] haproxy HTTPUpgrade ACL ditambahkan ke frontend/listen")
            modified = True
        else:
            print("    [warn] Tidak ada frontend/listen mode http ditemukan untuk inject ACL")
    else:
        print("    [skip] haproxy HTTPUpgrade ACL sudah ada")

    if modified:
        with open(CFG, "w") as f:
            f.write(content)
        print("    [ok] haproxy.cfg disimpan")

except Exception as e:
    print(f"    [error] haproxy inject: {e}")
HAPROXY_PY

# Validasi haproxy
if haproxy -c -f "$HAPROXY_CFG" 2>/dev/null; then
    echo -e "    ${green}[ok] haproxy config valid${neutral}"
else
    echo -e "    ${red}[err] haproxy config invalid! Restore backup...${neutral}"
    [ -f "${BACKUP_DIR}/haproxy.cfg" ] && cp "${BACKUP_DIR}/haproxy.cfg" "$HAPROXY_CFG"
    haproxy -c -f "$HAPROXY_CFG" 2>&1 | head -10
fi

# ─────────────────────────────────────────────────────────────────────────
# 5. RESTART SERVICES
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${yellow}[5/5] Restart semua service...${neutral}"

restart_svc() {
    local svc="$1"
    if systemctl is-enabled "$svc" &>/dev/null || systemctl is-active "$svc" &>/dev/null; then
        systemctl restart "$svc" 2>/dev/null && \
            echo -e "    ${green}[ok] $svc restarted${neutral}" || \
            echo -e "    ${red}[err] Gagal restart $svc${neutral}"
    else
        echo -e "    ${yellow}[skip] $svc tidak aktif${neutral}"
    fi
}

restart_svc "vmess@config.service"
restart_svc "vless@config.service"
restart_svc "trojan@config.service"
restart_svc "nginx.service"
restart_svc "haproxy.service"

# ─────────────────────────────────────────────────────────────────────────
# RINGKASAN
# ─────────────────────────────────────────────────────────────────────────
DOMAIN=$(cat /etc/xray/domain 2>/dev/null || echo "domain-kamu.com")
echo ""
echo -e "${orange}══════════════════════════════════════════${neutral}"
echo -e "${green}          UPDATE SELESAI!${neutral}"
echo -e "${orange}══════════════════════════════════════════${neutral}"
echo -e " ${blue}UUID aktif :${neutral} ${yellow}${OLD_UUID}${neutral}"
echo -e " ${blue}Domain     :${neutral} ${yellow}${DOMAIN}${neutral}"
echo -e "${orange}──────────────────────────────────────────${neutral}"
echo -e " ${blue}HTTPUpgrade endpoints:${neutral}"
echo -e "   VMess  → https://${DOMAIN}/vmess-hu"
echo -e "   VLess  → https://${DOMAIN}/vless-hu"
echo -e "   Trojan → https://${DOMAIN}/trojan-hu"
echo -e "${orange}──────────────────────────────────────────${neutral}"
echo -e " ${blue}Xray port  :${neutral} vmess=10009 | vless=10010 | trojan=10011"
echo -e " ${blue}Backup     :${neutral} ${yellow}${BACKUP_DIR}${neutral}"
echo -e "${orange}══════════════════════════════════════════${neutral}"
