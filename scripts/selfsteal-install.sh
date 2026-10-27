#!/bin/bash
# Sets up the Reality "selfsteal" decoy site on a node: Caddy serves a small
# static page for <domain> on 127.0.0.1:8443 (Xray dest) and gets the TLS
# certificate via HTTP-01 on port 80. Usage: sudo bash selfsteal-install.sh <domain>
set -e
D="$1"
case "$D" in
  *.*) ;;
  *) echo "Использование: selfsteal-install.sh <домен>"; exit 1;;
esac
mkdir -p /opt/selfsteal/site
cd /opt/selfsteal

cat > docker-compose.yml <<'YML'
services:
  caddy:
    image: caddy:2
    container_name: selfsteal-caddy
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./site:/srv:ro
      - ./data:/data
      - ./config:/config
YML

cat > Caddyfile <<CF
{
	http_port 80
	https_port 8443
}

http://$D {
	redir https://$D{uri} permanent
}

https://$D:8443 {
	bind 127.0.0.1
	root * /srv
	file_server
	header -Server
}
CF

if [ ! -f site/index.html ]; then
cat > site/index.html <<'HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Nordic Light — photo journal</title>
<style>
body{margin:0;font-family:Georgia,serif;background:#f4f1ec;color:#222}
header{padding:48px 24px 24px;text-align:center}
h1{font-weight:normal;letter-spacing:2px;margin:0}
p.sub{color:#777;margin:8px 0 0;font-style:italic}
main{max-width:960px;margin:0 auto;padding:24px;display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:16px}
.card{background:#fff;border-radius:4px;overflow:hidden;box-shadow:0 1px 3px rgba(0,0,0,.08)}
.ph{height:160px}
.card div.t{padding:12px 14px;font-size:14px;color:#555}
footer{text-align:center;color:#999;font-size:13px;padding:32px}
</style>
</head>
<body>
<header><h1>Nordic Light</h1><p class="sub">Notes and photographs from the north</p></header>
<main>
<div class="card"><div class="ph" style="background:linear-gradient(160deg,#9fb8c8,#e6e1d6)"></div><div class="t">Morning fog over the lake</div></div>
<div class="card"><div class="ph" style="background:linear-gradient(160deg,#6d8a74,#c9d3c0)"></div><div class="t">Birch forest in late autumn</div></div>
<div class="card"><div class="ph" style="background:linear-gradient(160deg,#3d4f6b,#a7b4c9)"></div><div class="t">Harbour at blue hour</div></div>
<div class="card"><div class="ph" style="background:linear-gradient(160deg,#c9a27e,#efe3d3)"></div><div class="t">Old wooden houses</div></div>
<div class="card"><div class="ph" style="background:linear-gradient(160deg,#7f8c99,#dfe4ea)"></div><div class="t">First snow on the coast</div></div>
<div class="card"><div class="ph" style="background:linear-gradient(160deg,#4f6d5d,#b8c9bd)"></div><div class="t">Island trail</div></div>
</main>
<footer>&copy; Nordic Light</footer>
</body>
</html>
HTML
fi

command -v ufw >/dev/null && ufw allow 80/tcp >/dev/null && echo "порт 80 открыт (нужен для сертификата)"
docker compose up -d 2>&1 | tail -2
echo "--- ждём сертификат (до 40 сек)..."
for i in $(seq 1 20); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --resolve "$D:8443:127.0.0.1" "https://$D:8443/" || true)
  [ "$code" = "200" ] && break
  sleep 2
done
echo "--- проверка сайта: HTTP $code"
if [ "$code" = "200" ]; then
  echo "OK: сайт-маскировка работает, сертификат получен"
else
  echo "Сертификат пока не получен. Журнал:"
  docker logs --tail 15 selfsteal-caddy 2>&1 | grep -iE 'error|obtain|challenge|certificate' | tail -8
fi
rm -f /tmp/ss.sh
