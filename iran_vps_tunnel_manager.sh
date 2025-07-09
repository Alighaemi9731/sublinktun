#!/bin/bash
set -e

SCRIPT_URL="https://raw.githubusercontent.com/Alighaemi9731/sublinktun/main/iran_vps_tunnel_manager.sh"
INSTALL_PATH="/usr/local/bin/iran_vps_tunnel_manager.sh"
CONFIG_FILE="/etc/nginx/.iran_vps_tunnels"
EMAIL="alighaemi@gmail.com"

# --- Self-updater: If running not from install path, download and exec there
if [[ "$0" != "$INSTALL_PATH" ]]; then
  sudo mkdir -p "$(dirname "$INSTALL_PATH")"
  sudo curl -fsSL "$SCRIPT_URL" -o "$INSTALL_PATH"
  sudo chmod +x "$INSTALL_PATH"
  exec sudo "$INSTALL_PATH"
  exit
fi

# --- Ensure root
if [[ $EUID -ne 0 ]]; then
   echo "Please run as root (sudo)." 1>&2
   exit 1
fi

# --- Trap for clean exit
trap 'echo; echo "Exiting..."; exit 0' SIGINT

# --- Prepare dependencies
function install_requirements() {
  apt update && apt install -y nginx certbot python3-certbot-nginx curl
  mkdir -p /var/cache/nginx
  chown -R www-data:www-data /var/cache/nginx
}

# --- Write main nginx.conf (idempotent)
function setup_nginx_conf() {
  local conf="/etc/nginx/nginx.conf"
  if ! grep -q 'proxy_cache_path /var/cache/nginx' "$conf"; then
    cat > "$conf" <<EOL
user www-data;
worker_processes auto;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    proxy_cache_path /var/cache/nginx levels=1:2 keys_zone=my_cache:50m inactive=60m use_temp_path=off;
    server_names_hash_bucket_size 64;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOL
  fi
}

# --- Add tunnel
function add_tunnel() {
  echo -e "\n[ADD TUNNEL]"
  read -rp "Enter subdomain (e.g. sub.example.com): " SUB
  [[ -z "$SUB" ]] && echo "Subdomain is required!" && return

  read -rp "Enter backend/origin IP (e.g. 192.168.1.10): " IP
  [[ -z "$IP" ]] && echo "IP is required!" && return

  # Check existence
  if grep -qw "$SUB|" "$CONFIG_FILE" 2>/dev/null; then
    echo "This subdomain is already configured."
    return
  fi

  # Write Nginx config
  local CFG="/etc/nginx/sites-available/${SUB}.conf"
  cat > "$CFG" <<EOL
server {
    listen 80;
    listen [::]:80;
    server_name $SUB;

    location / {
        proxy_pass https://$IP;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_ssl_server_name on;
        proxy_ssl_name $SUB;
        proxy_cache my_cache;
        proxy_cache_valid 200 302 30m;
        proxy_cache_valid 404 1m;
    }
}
EOL

  ln -sf "$CFG" /etc/nginx/sites-enabled/
  echo "$SUB|$IP" >> "$CONFIG_FILE"

  nginx -t && systemctl reload nginx
  certbot --nginx --non-interactive --agree-tos --email "$EMAIL" -d "$SUB" || true

  echo -e "Tunnel added for $SUB -> $IP\n"
  sleep 1
}

# --- List/Delete tunnel
function list_delete_tunnel() {
  echo -e "\n[MANAGE TUNNELS]"
  if [[ ! -s "$CONFIG_FILE" ]]; then
    echo "No tunnels configured yet."
    return
  fi
  local count=0
  declare -A IDX2SUB
  while IFS='|' read -r sub ip; do
    ((count++))
    echo "[$count] $sub  -->  $ip"
    IDX2SUB[$count]="$sub"
  done < "$CONFIG_FILE"
  echo "[0] Back"

  read -rp "Select number to delete, or 0 to return: " choice
  [[ "$choice" =~ ^[0-9]+$ ]] || return
  [[ "$choice" == "0" ]] && return
  local sel_sub="${IDX2SUB[$choice]}"
  [[ -z "$sel_sub" ]] && echo "Invalid choice." && return

  # Remove files
  rm -f "/etc/nginx/sites-enabled/${sel_sub}.conf" "/etc/nginx/sites-available/${sel_sub}.conf"
  sed -i "/^${sel_sub}|/d" "$CONFIG_FILE"
  nginx -t && systemctl reload nginx
  certbot delete --cert-name "$sel_sub" --non-interactive || true
  echo "Tunnel for $sel_sub deleted."
  sleep 1
}

# --- Remove all
function remove_all() {
  echo -e "\n[REMOVE EVERYTHING]"
  read -rp "Are you sure you want to remove all tunnels and config done by this script? [y/N]: " yn
  [[ "${yn,,}" == "y" ]] || return

  # Remove all tunnels
  if [[ -s "$CONFIG_FILE" ]]; then
    while IFS='|' read -r sub ip; do
      rm -f "/etc/nginx/sites-enabled/${sub}.conf" "/etc/nginx/sites-available/${sub}.conf"
      certbot delete --cert-name "$sub" --non-interactive || true
    done < "$CONFIG_FILE"
    rm -f "$CONFIG_FILE"
  fi
  # Optionally restore nginx.conf, left for safety.
  nginx -t && systemctl reload nginx
  echo "All tunnels and script configs have been removed."
  sleep 1
}

# --- Certbot renewal cron
function setup_cron() {
  crontab -l 2>/dev/null | grep -q 'certbot renew' || \
    (crontab -l 2>/dev/null; echo "0 12 * * * /usr/bin/certbot renew --quiet") | crontab -
}

# --- Main menu
function main_menu() {
  while true; do
    clear
    echo "====== Iran VPS Tunnel Manager ======"
    echo " 1) Add new tunnel"
    echo " 2) List & delete tunnels"
    echo " 3) Remove all tunnels and configs"
    echo " 4) Exit"
    echo "------------------------------------"
    read -rp "Choose an option [1-4]: " opt
    case "$opt" in
      1) add_tunnel ;;
      2) list_delete_tunnel ;;
      3) remove_all ;;
      4) echo "Bye!"; exit 0 ;;
      *) echo "Invalid option!"; sleep 1 ;;
    esac
  done
}

# --- Main run
install_requirements
setup_nginx_conf
setup_cron
main_menu
