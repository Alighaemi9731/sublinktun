#!/bin/bash

# Configuration
CONFIG_DIR="/etc/iran_vps_tunnel"
CONFIG_FILE="${CONFIG_DIR}/config.txt"
SCRIPT_PATH="/usr/local/bin/iran_vps_tunnel_manager"
SCRIPT_URL="https://raw.githubusercontent.com/Alighaemi9731/sublinktun/main/iran_vps_tunnel_manager.sh"
EMAIL="alighaemi@gmail.com"  # Certbot email

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Install script if not present
install_script() {
    echo -e "${YELLOW}Installing Iran VPS Tunnel Manager...${NC}"
    mkdir -p "${CONFIG_DIR}"
    touch "${CONFIG_FILE}"
    curl -sL "${SCRIPT_URL}" -o "${SCRIPT_PATH}"
    chmod +x "${SCRIPT_PATH}"
    echo -e "${GREEN}Installation complete! Running manager...${NC}"
    sleep 2
    "${SCRIPT_PATH}"
    exit 0
}

# Check if we need to install
if [ ! -d "${CONFIG_DIR}" ] || [ ! -f "${SCRIPT_PATH}" ]; then
    install_script
fi

# Main Functions
initial_nginx_setup() {
    echo -e "${YELLOW}Setting up Nginx environment...${NC}"
    apt update > /dev/null 2>&1
    apt install -y nginx certbot python3-certbot-nginx > /dev/null 2>&1
    
    # Create cache directory
    mkdir -p /var/cache/nginx
    chown -R www-data:www-data /var/cache/nginx

    # Configure main nginx.conf
    if ! grep -q "proxy_cache_path" /etc/nginx/nginx.conf; then
        cat > /etc/nginx/nginx.conf <<EOL
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
    echo -e "${GREEN}Nginx setup complete!${NC}"
    sleep 1
}

add_tunnel() {
    clear
    echo -e "${YELLOW}=== Add New Tunnel ===${NC}"
    
    while true; do
        read -p "Enter subdomain (e.g., example.domain.com): " subdomain
        if [[ "$subdomain" =~ ^[a-zA-Z0-9.-]+$ ]]; then
            break
        else
            echo -e "${RED}Invalid subdomain format!${NC}"
        fi
    done
    
    while true; do
        read -p "Enter origin server IP: " origin_ip
        if [[ "$origin_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            break
        else
            echo -e "${RED}Invalid IP address!${NC}"
        fi
    done

    # Save to config
    echo "${subdomain}=${origin_ip}" >> "${CONFIG_FILE}"
    
    # Initial Nginx setup if needed
    if ! nginx -v > /dev/null 2>&1; then
        initial_nginx_setup
    fi

    # Create Nginx config
    cat > "/etc/nginx/sites-available/${subdomain}.conf" <<EOL
server {
    listen 80;
    listen [::]:80;
    server_name ${subdomain};

    location / {
        proxy_pass https://${origin_ip};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        
        proxy_ssl_server_name on;
        proxy_ssl_name ${subdomain};
        
        proxy_cache my_cache;
        proxy_cache_valid 200 302 30m;
        proxy_cache_valid 404 1m;
    }
}
EOL

    # Enable site
    ln -sf "/etc/nginx/sites-available/${subdomain}.conf" "/etc/nginx/sites-enabled/"
    
    # Test and reload Nginx
    if nginx -t; then
        systemctl reload nginx
        echo -e "${GREEN}Nginx configuration validated!${NC}"
    else
        echo -e "${RED}Nginx configuration error! Check logs.${NC}"
        return 1
    fi

    # Get SSL certificate
    echo -e "${YELLOW}Requesting SSL certificate...${NC}"
    certbot --nginx -d "${subdomain}" --non-interactive --agree-tos --email "${EMAIL}"
    
    # Setup renewal cron if not exists
    if ! crontab -l | grep -q "certbot renew"; then
        (crontab -l 2>/dev/null; echo "0 12 * * * /usr/bin/certbot renew --quiet") | crontab -
    fi

    echo -e "${GREEN}\nTunnel added successfully!${NC}"
    echo -e "Remember to add Cloudflare DNS records:\n1. Proxied A record → Main server\n2. Non-proxied A record → Iran VPS IP"
    read -p "Press [Enter] to continue"
}

delete_tunnel() {
    local domain=$1
    local ip=$2
    
    # Remove from config
    sed -i "/^${domain}=/d" "${CONFIG_FILE}"
    
    # Remove Nginx configs
    rm -f "/etc/nginx/sites-available/${domain}.conf"
    rm -f "/etc/nginx/sites-enabled/${domain}.conf"
    
    # Remove Certbot certificate
    certbot delete --cert-name "${domain}" --non-interactive > /dev/null 2>&1
    
    # Reload Nginx
    systemctl reload nginx
    
    echo -e "${GREEN}Tunnel for ${domain} removed!${NC}"
    sleep 1
}

manage_tunnels() {
    while true; do
        clear
        echo -e "${YELLOW}=== Manage Tunnels ===${NC}"
        
        if [ ! -s "${CONFIG_FILE}" ]; then
            echo -e "${RED}No tunnels configured!${NC}"
            read -p "Press [Enter] to return"
            return
        fi

        declare -A tunnels
        i=1
        while IFS="=" read -r domain ip; do
            tunnels[$i]="$domain:$ip"
            echo "$i. $domain → $ip"
            ((i++))
        done < "${CONFIG_FILE}"
        
        echo -e "\n$i. Back to Main Menu"
        read -p "Select tunnel to delete: " choice
        
        if [ "$choice" -eq "$i" ] 2>/dev/null; then
            return
        elif [ "$choice" -gt 0 ] && [ "$choice" -lt "$i" ] 2>/dev/null; then
            IFS=':' read -r domain ip <<< "${tunnels[$choice]}"
            read -p $"Delete tunnel for ${RED}${domain}${NC}? [y/N]: " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                delete_tunnel "$domain" "$ip"
            fi
        else
            echo -e "${RED}Invalid selection!${NC}"
            sleep 1
        fi
    done
}

uninstall_all() {
    clear
    echo -e "${RED}=== COMPLETE UNINSTALL ===${NC}"
    read -p "This will remove ALL tunnels and configurations! Continue? [y/N]: " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        return
    fi
    
    # Remove all tunnels
    while IFS="=" read -r domain ip; do
        delete_tunnel "$domain" "$ip"
    done < "${CONFIG_FILE}"
    
    # Remove config directory
    rm -rf "${CONFIG_DIR}"
    
    # Remove script
    rm -f "${SCRIPT_PATH}"
    
    # Remove cronjob
    crontab -l | grep -v "certbot renew" | crontab -
    
    echo -e "${GREEN}Uninstallation complete! All components removed.${NC}"
    exit 0
}

# Main Menu
while true; do
    clear
    echo -e "${YELLOW}===================================${NC}"
    echo -e "${YELLOW}    Iran VPS Tunnel Manager        ${NC}"
    echo -e "${YELLOW}===================================${NC}"
    echo "1. Add new tunnel"
    echo "2. Manage existing tunnels"
    echo "3. COMPLETE UNINSTALL"
    echo "4. Exit"
    echo -e "${YELLOW}===================================${NC}"
    
    read -p "Choose option: " choice
    case $choice in
        1) add_tunnel ;;
        2) manage_tunnels ;;
        3) uninstall_all ;;
        4) exit 0 ;;
        *) echo -e "${RED}Invalid option!${NC}"; sleep 1 ;;
    esac
done
