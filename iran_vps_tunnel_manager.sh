#!/bin/bash

# --- Global Variables ---
SCRIPT_NAME="iran_vps_tunnel_manager.sh"
GITHUB_RAW_URL="https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/YOUR_REPOSITORY_NAME/main/${SCRIPT_NAME}" # <<< IMPORTANT: Update this line
CONFIG_DIR="/etc/nginx_tunnel_manager"
CONFIG_FILE="${CONFIG_DIR}/domains.conf"
NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
EMAIL_FOR_CERTBOT="your-email@example.com" # <<< IMPORTANT: Update this line

# --- Text Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Helper Functions ---

log_message() {
    local type="$1"
    local message="$2"
    case "$type" in
        "info") echo -e "${BLUE}[INFO]${NC} ${message}" ;;
        "success") echo -e "${GREEN}[SUCCESS]${NC} ${message}" ;;
        "warning") echo -e "${YELLOW}[WARNING]${NC} ${message}" ;;
        "error") echo -e "${RED}[ERROR]${NC} ${message}" >&2 ;;
    esac
}

press_enter_to_continue() {
    log_message "info" "Press Enter to continue..."
    read -r
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_message "error" "This script must be run as root."
        exit 1
    fi
}

# Function to ensure Nginx and Certbot are installed and configured
install_dependencies() {
    log_message "info" "Checking for updates and installing dependencies (Nginx, Certbot)..."
    apt update -y || { log_message "error" "Failed to update package lists."; return 1; }
    apt upgrade -y || { log_message "warning" "Failed to upgrade packages, continuing..."; }
    apt install -y nginx certbot python3-certbot-nginx || { log_message "error" "Failed to install required packages."; return 1; }
    log_message "success" "Dependencies installed."

    log_message "info" "Setting up Nginx cache directory..."
    mkdir -p /var/cache/nginx || { log_message "error" "Failed to create Nginx cache directory."; return 1; }
    chown -R www-data:www-data /var/cache/nginx || { log_message "error" "Failed to set ownership for Nginx cache."; return 1; }
    log_message "success" "Nginx cache directory configured."

    log_message "info" "Configuring main Nginx settings..."
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
    log_message "success" "Main Nginx configuration applied."
    return 0
}

# Function to load domains from the config file
load_domains() {
    declare -g -A DOMAINS # Declare as global associative array
    if [[ -f "$CONFIG_FILE" ]]; then
        while IFS='=' read -r domain ip; do
            if [[ -n "$domain" && -n "$ip" ]]; then
                DOMAINS["$domain"]="$ip"
            fi
        done < "$CONFIG_FILE"
        log_message "info" "Loaded $(wc -l < "$CONFIG_FILE") domains from ${CONFIG_FILE}."
    else
        log_message "warning" "Configuration file ${CONFIG_FILE} not found. Starting fresh."
        mkdir -p "$CONFIG_DIR" || { log_message "error" "Failed to create config directory."; return 1; }
        touch "$CONFIG_FILE" || { log_message "error" "Failed to create config file."; return 1; }
    fi
    return 0
}

# Function to save domains to the config file
save_domains() {
    > "$CONFIG_FILE" # Clear the file
    for domain in "${!DOMAINS[@]}"; do
        echo "${domain}=${DOMAINS[$domain]}" >> "$CONFIG_FILE"
    done
    log_message "success" "Domains saved to ${CONFIG_FILE}."
}

# Function to generate Nginx config for a domain
generate_nginx_config() {
    local domain="$1"
    local origin_ip="$2"
    local config_path="${NGINX_SITES_AVAILABLE}/${domain}.conf"

    cat > "$config_path" <<EOL
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    location / {
        proxy_pass https://${origin_ip};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        
        proxy_ssl_server_name on;
        proxy_ssl_name ${domain};
        
        proxy_cache my_cache;
        proxy_cache_valid 200 302 30m;
        proxy_cache_valid 404 1m;
    }

    # Redirect HTTP to HTTPS after Certbot
    # listen 443 ssl http2;
    # listen [::]:443 ssl http2;
    # ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    # ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    # include /etc/letsencrypt/options-ssl-nginx.conf;
    # ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; # uncomment if you run certbot with --ssl-dhparam

}
EOL
    log_message "info" "Generated Nginx config for ${domain} at ${config_path}."
    return 0
}

# Function to enable Nginx config
enable_nginx_config() {
    local domain="$1"
    local available_path="${NGINX_SITES_AVAILABLE}/${domain}.conf"
    local enabled_path="${NGINX_SITES_ENABLED}/${domain}.conf"

    if [[ -f "$available_path" ]]; then
        ln -sf "$available_path" "$enabled_path" || { log_message "error" "Failed to enable Nginx config for ${domain}."; return 1; }
        log_message "success" "Enabled Nginx config for ${domain}."
        return 0
    else
        log_message "error" "Nginx config file not found for ${domain} at ${available_path}."
        return 1
    fi
}

# Function to disable Nginx config
disable_nginx_config() {
    local domain="$1"
    local enabled_path="${NGINX_SITES_ENABLED}/${domain}.conf"
    local available_path="${NGINX_SITES_AVAILABLE}/${domain}.conf"

    if [[ -L "$enabled_path" ]]; then
        rm "$enabled_path" || { log_message "error" "Failed to disable Nginx config for ${domain}."; return 1; }
        log_message "success" "Disabled Nginx config symlink for ${domain}."
    fi
    if [[ -f "$available_path" ]]; then
        rm "$available_path" || { log_message "error" "Failed to remove Nginx config file for ${domain}."; return 1; }
        log_message "success" "Removed Nginx config file for ${domain}."
    fi
    return 0
}

# Function to apply Certbot for a domain
apply_certbot() {
    local domain="$1"
    log_message "info" "Attempting to get SSL certificate for ${domain}..."
    certbot --nginx -d "${domain}" --non-interactive --agree-tos --email "${EMAIL_FOR_CERTBOT}" || { log_message "warning" "Certbot failed for ${domain}. Please check DNS A record."; return 1; }
    log_message "success" "SSL certificate obtained for ${domain}."
    return 0
}

# Function to update Nginx configs to use HTTPS after Certbot
update_nginx_to_https() {
    local domain="$1"
    local config_path="${NGINX_SITES_AVAILABLE}/${domain}.conf"

    if grep -q "listen 443 ssl" "$config_path"; then
        log_message "info" "HTTPS configuration already present for ${domain}."
        return 0
    fi

    log_message "info" "Updating Nginx config for ${domain} to redirect to HTTPS and use SSL..."
    # First, make a temporary file with the updated content
    sed -i "/listen 80;/a \    listen 443 ssl http2;\n    listen [::]:443 ssl http2;\n    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;\n    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;\n    include /etc/letsencrypt/options-ssl-nginx.conf;\n    # ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; # uncomment if you run certbot with --ssl-dhparam\n\n    if (\$scheme != \"https\") {\n        return 301 https://\$host\$request_uri;\n    }" "${config_path}"

    if [[ $? -ne 0 ]]; then
        log_message "error" "Failed to update Nginx config for HTTPS for ${domain}."
        return 1
    fi
    log_message "success" "Nginx config updated for ${domain} to use HTTPS."
    return 0
}


# --- Main Menu Options ---

add_domain() {
    clear
    log_message "info" "--- Add New Subdomain Tunnel ---"
    read -rp "Enter the subdomain (e.g., ops.example.com): " subdomain
    subdomain=$(echo "$subdomain" | tr '[:upper:]' '[:lower:]') # Convert to lowercase

    if [[ -z "$subdomain" ]]; then
        log_message "error" "Subdomain cannot be empty."
        press_enter_to_continue
        return
    fi

    if [[ "${DOMAINS[$subdomain]}" ]]; then
        log_message "warning" "Subdomain '${subdomain}' already exists with IP: ${DOMAINS[$subdomain]}."
        press_enter_to_continue
        return
    fi

    read -rp "Enter the main server IP for ${subdomain}: " ip_address

    if [[ ! "$ip_address" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        log_message "error" "Invalid IP address format."
        press_enter_to_continue
        return
    fi

    log_message "info" "Adding ${subdomain} pointing to ${ip_address}..."
    DOMAINS["$subdomain"]="$ip_address"
    save_domains

    generate_nginx_config "$subdomain" "$ip_address" && \
    enable_nginx_config "$subdomain" && \
    systemctl reload nginx && \
    log_message "success" "Nginx reloaded for initial HTTP config." && \
    apply_certbot "$subdomain" && \
    update_nginx_to_https "$subdomain" && \
    systemctl reload nginx && \
    log_message "success" "Successfully added and configured ${subdomain} with SSL." || \
    log_message "error" "Failed to add and configure ${subdomain}. Please check logs."

    log_message "info" "--- IMPORTANT Cloudflare Steps ---"
    log_message "info" "1. In Cloudflare, keep your existing **proxied (orange cloud)** A record for '${subdomain}' pointing to your main server."
    log_message "info" "2. Add a **SECOND A record** for '${subdomain}' (or your main domain if this is root) with:"
    log_message "info" "   - **Name:** '${subdomain}'"
    log_message "info" "   - **Content:** The IP address of **THIS Iran VPS**"
    log_message "info" "   - **Proxy status:** DISABLED (gray cloud)"
    log_message "info" "This setup ensures the Iran VPS handles traffic from Iran, and your main server handles direct traffic."
    
    press_enter_to_continue
}

list_and_delete_domain() {
    clear
    log_message "info" "--- List and Delete Subdomain Tunnels ---"
    if [[ ${#DOMAINS[@]} -eq 0 ]]; then
        log_message "warning" "No subdomains configured yet."
        press_enter_to_continue
        return
    fi

    local i=1
    local domain_list=()
    log_message "info" "Current Subdomains:"
    for domain in "${!DOMAINS[@]}"; do
        log_message "info" "${i}. ${domain} -> ${DOMAINS[$domain]}"
        domain_list+=("$domain")
        ((i++))
    done

    echo ""
    read -rp "Enter the number of the subdomain to delete, or 0 to return to main menu: " choice

    if [[ "$choice" -eq 0 ]]; then
        log_message "info" "Returning to main menu."
        return
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "${#domain_list[@]}" ]]; then
        local domain_to_delete="${domain_list[choice-1]}"
        read -rp "Are you sure you want to delete '${domain_to_delete}'? (y/N): " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            log_message "info" "Deleting ${domain_to_delete}..."
            disable_nginx_config "$domain_to_delete"
            # Attempt to remove Certbot certificate if it exists
            certbot delete --non-interactive --cert-name "$domain_to_delete" &>/dev/null
            if [[ $? -eq 0 ]]; then
                log_message "success" "Certbot certificate for ${domain_to_delete} removed."
            else
                log_message "warning" "No Certbot certificate found or failed to remove for ${domain_to_delete}."
            fi
            
            unset DOMAINS["$domain_to_delete"]
            save_domains
            systemctl reload nginx || log_message "error" "Failed to reload Nginx after deletion."
            log_message "success" "Successfully deleted ${domain_to_delete}."
        else
            log_message "info" "Deletion cancelled."
        fi
    else
        log_message "error" "Invalid choice."
    fi
    press_enter_to_continue
}

remove_all() {
    clear
    log_message "warning" "--- Remove Everything ---"
    read -rp "This will remove all Nginx configurations, Certbot data, and dependencies installed by this script. Are you absolutely sure? (y/N): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        log_message "info" "Proceeding with complete removal..."

        # Stop and disable Nginx
        systemctl stop nginx &>/dev/null
        systemctl disable nginx &>/dev/null
        log_message "info" "Nginx stopped and disabled."

        # Remove all Nginx site configs
        log_message "info" "Removing Nginx site configurations..."
        rm -rf "${NGINX_SITES_AVAILABLE}"/* &>/dev/null
        rm -rf "${NGINX_SITES_ENABLED}"/* &>/dev/null
        # Restore default Nginx conf, or remove it entirely
        # For simplicity, let's remove everything for now.
        rm -f /etc/nginx/nginx.conf &>/dev/null
        rm -rf /var/cache/nginx &>/dev/null
        log_message "success" "Nginx site configurations and cache removed."

        # Remove Certbot certificates and data
        log_message "info" "Removing Certbot certificates and data..."
        certbot unregister --non-interactive || log_message "warning" "Certbot unregister failed or no account exists."
        rm -rf /etc/letsencrypt &>/dev/null
        log_message "success" "Certbot data removed."

        # Remove config file and directory
        log_message "info" "Removing script configuration file and directory..."
        rm -rf "$CONFIG_DIR" &>/dev/null
        log_message "success" "Script configuration removed."

        # Remove installed packages
        log_message "info" "Removing Nginx, Certbot, and Python packages..."
        apt purge -y nginx certbot python3-certbot-nginx &>/dev/null
        apt autoremove -y &>/dev/null
        log_message "success" "Dependencies purged."
        
        # Remove cron job for certbot renewal
        log_message "info" "Removing Certbot renewal cron job..."
        (crontab -l 2>/dev/null | grep -v 'certbot renew' | crontab -) &>/dev/null
        log_message "success" "Certbot renewal cron job removed."

        # Remove the script itself
        log_message "info" "Removing the script itself..."
        rm -f "$(readlink -f "$0")" &>/dev/null # Get the real path of the script
        log_message "success" "Script ${SCRIPT_NAME} removed."

        log_message "success" "All components installed by this script have been removed."
        log_message "info" "You may need to reboot your server for all changes to take full effect."
        exit 0
    else
        log_message "info" "Removal cancelled."
    fi
    press_enter_to_continue
}

# --- Main Menu Logic ---

display_menu() {
    clear
    log_message "info" "--- Iran VPS Nginx Tunnel Manager ---"
    echo ""
    echo "1. ${GREEN}Add New Subdomain Tunnel${NC}"
    echo "2. ${YELLOW}List and Delete Subdomain Tunnel${NC}"
    echo "3. ${RED}Remove All Script Data and Dependencies${NC}"
    echo "4. ${BLUE}Exit${NC}"
    echo ""
    read -rp "Enter your choice: " choice
    case "$choice" in
        1) add_domain ;;
        2) list_and_delete_domain ;;
        3) remove_all ;;
        4) log_message "info" "Exiting. Goodbye!"; exit 0 ;;
        *) log_message "error" "Invalid choice. Please try again."; press_enter_to_continue ;;
    esac
}

# --- Initial Script Execution Check ---

self_download_and_run() {
    local script_path="/usr/local/bin/${SCRIPT_NAME}" # A common place for user-managed scripts
    
    if [[ ! -f "$script_path" || "$1" == "force_download" ]]; then
        log_message "info" "Script not found locally or forced download. Downloading ${SCRIPT_NAME} from GitHub..."
        if command -v curl &>/dev/null; then
            curl -sL "$GITHUB_RAW_URL" -o "$script_path"
        elif command -v wget &>/dev/null; then
            wget -qO "$script_path" "$GITHUB_RAW_URL"
        else
            log_message "error" "Neither curl nor wget found. Please install one to download the script."
            exit 1
        fi
        
        if [[ $? -ne 0 ]]; then
            log_message "error" "Failed to download ${SCRIPT_NAME} from GitHub. Check the URL and your network connection."
            exit 1
        fi
        chmod +x "$script_path"
        log_message "success" "${SCRIPT_NAME} downloaded to ${script_path} and made executable."
        exec "$script_path" # Execute the downloaded script
    else
        log_message "info" "${SCRIPT_NAME} already exists at ${script_path}. Opening menu."
    fi
}

# --- Main Execution Flow ---
check_root

# If the script is executed directly from GitHub or not yet installed,
# it will attempt to download itself to /usr/local/bin/ and then execute.
# Otherwise, it will just proceed to the main logic.
if [[ "$(basename "$0")" == "$SCRIPT_NAME" ]]; then
    # If this is the downloaded script, proceed
    load_domains
    if install_dependencies; then
        # Set up certbot renewal only once if not already set
        if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
            (crontab -l 2>/dev/null; echo "0 12 * * * /usr/bin/certbot renew --quiet") | crontab -
            log_message "success" "Certbot renewal cron job added."
        fi
        while true; do
            display_menu
        done
    else
        log_message "error" "Initial setup failed. Exiting."
        exit 1
    fi
else
    # This is the initial execution that will self-download
    self_download_and_run
fi
