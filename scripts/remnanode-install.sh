#!/bin/bash
# Installs a Remnawave node (remnanode) in /opt/remnanode.
# The node SECRET_KEY is read from stdin, never passed as an argument:
#   Get-Content key.txt | ssh user@host "curl -fsSL <this url> -o /tmp/mk.sh && sudo bash /tmp/mk.sh"
set -e
K=$(tr -d '\r\n ')
case "$K" in
  eyJ*) ;;
  *) echo "ОШИБКА: в буфере обмена не ключ ноды. Скопируйте Secret Key в панели ещё раз и повторите команду."; rm -f /tmp/mk.sh; exit 1;;
esac
mkdir -p /opt/remnanode
cat > /opt/remnanode/docker-compose.yml <<YML
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=2222
      - SECRET_KEY=$K
YML
chmod 600 /opt/remnanode/docker-compose.yml
rm -f /tmp/mk.sh
cd /opt/remnanode
docker compose up -d 2>&1 | tail -3
sleep 10
echo "--- статус:"
docker ps --filter name=remnanode --format '{{.Names}} {{.Status}}'
echo "--- журнал:"
docker logs --tail 12 remnanode 2>&1 | grep -iv secret
