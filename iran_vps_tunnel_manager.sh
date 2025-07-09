#!/bin/bash

# --- Global Variables ---
SCRIPT_NAME="iran_vps_tunnel_manager.sh"
# IMPORTANT: Update this line with your GitHub repository's raw URL for the script
# Example: https://raw.githubusercontent.com/Alighaemi9731/sublinktun/main/iran_vps_tunnel_manager.sh
GITHUB_RAW_URL="https://raw.githubusercontent.com/Alighaemi9731/sublinktun/main/${SCRIPT_NAME}"
CONFIG_DIR="/etc/nginx_tunnel_manager"
CONFIG_FILE="${CONFIG_DIR}/domains.conf"
NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
# IMPORTANT: Update this line with your actual email for Certbot notifications
EMAIL_FOR_CERTBOT="your-email@example.com"

# --- Text Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Helper Functions ---

# Function for standardized logging
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

# Function to pause execution until user presses Enter
press_enter_to_continue() {
    log_message "info" "Press Enter to continue..."
    read -r
}

# Function to ensure the script is run as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_message "error" "This script must be run as root."
        exit 1
    fi
}

# Function to install Nginx and Certbot
install_dependencies() {
    log_message "info" "Updating system and installing dependencies (Nginx, Certbot)..."
    apt update -y || { log_message "error" "Failed to update package lists."; return 1; }
    apt upgrade -y || { log_message "warning" "Failed to upgrade packages, continuing..."; }

    # Try to install Certbot via snapd first (recommended for latest version)
    if ! command -v certbot &>/dev/null || [[ "$(certbot --version 2>&1)" =~ "command not found" ]]; then
        log_message "info" "Attempting to install Certbot via snapd..."
        if ! command -v snap &>/dev/null; then
            log_message "info" "snapd not found, installing snapd..."
            apt install snapd -y || { log_message "error" "Failed to install snapd."; return 1; }
            log_message "success" "snapd installed."
            systemctl enable --now snapd.socket || log_message "warning" "Failed to enable snapd socket."
            # Ensure /snap is symlinked for older systems, common on VPS
            if [[ ! -d /snap && -d /var/lib/snapd/snap ]]; then
                ln -s /var/lib/snapd/snap /snap || log_message "warning" "Failed to create /snap symlink."
            fi
        fi
        
        sudo snap install core || log_message "warning" "Failed to install snap core."
        sudo snap refresh core || log_message "warning" "Failed to refresh snap core."
        sudo snap install --classic certbot || { log_message "error" "Failed to install Certbot via snapd."; return 1; }
        
        # Create symlink for certbot command if not already in PATH
        if ! command -v certbot &>/dev/null; then
            ln -s /snap/bin/certbot /usr/bin/certbot || log_message "warning" "Failed to create certbot symlink to /usr/bin. You might need to use /snap/bin/certbot directly."
        fi
        log_message "success" "Certbot installed via snapd."
    else
        log_message "info" "Certbot already installed. Skipping snapd installation."
    fi

    # Install Nginx (if not already present)
    if ! command -v nginx &>/dev/null; then
        log_message "info" "Installing Nginx..."
        apt install nginx -y || { log_message "error" "Failed to install Nginx."; return 1; }
        log_message "success" "Nginx installed."
    else
        log_message "info" "Nginx already installed."
    fi

    log_message "success" "Required dependencies (Nginx, Certbot) checked/installed."

    log_message "info" "Setting up Nginx cache directory..."
    mkdir -p /var/cache/nginx || { log_message "error" "Failed to create Nginx cache directory. Check permissions."; return 1; }
    chown -R www-data:www-data /var/cache/nginx || { log_message "error" "Failed to set ownership for Nginx cache. Check permissions."; return 1; }
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
            # Trim whitespace from domain and ip
            domain=$(echo "$domain" | xargs)
            ip=$(echo "$ip" | xargs)
            if [[ -n "$domain" && -n "$ip" ]]; then
                DOMAINS["$domain"]="$ip"
            fi
        done < "$CONFIG_FILE"
        log_message "info" "Loaded $(wc -l < "$CONFIG_FILE" 2>/dev/null || echo "0") domains from ${CONFIG_FILE}."
    else
        log_message "warning" "Configuration file ${CONFIG_FILE} not found. Starting fresh."
        mkdir -p "$CONFIG_DIR" || { log_message "error" "Failed to create config directory '${CONFIG_DIR}'. Check permissions."; return 1; }
        touch "$CONFIG_FILE" || { log_message "error" "Failed to create config file '${CONFIG_FILE}'. Check permissions."; return 1; }
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

# Function to validate a domain name
is_valid_domain() {
    local domain="$1"
    # Basic regex for domain validation (not exhaustive, but good enough for common use)
    [[ "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

# Function to validate an IP address
is_valid_ip() {
    local ip="$1"
    # Basic regex for IPv4 validation
    if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        # Further check octet ranges
        local IFS='.'
        read -r o1 o2 o3 o4 <<< "$ip"
        [[ "$o1" -le 255 && "$o2" -le 255 && "$o3" -le 255 && "$o4" -le 255 ]]
    else
        return 1 # Not a valid format
    fi
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

    # Certbot will automatically add/uncomment the HTTPS configuration here
    # after it successfully obtains the certificate.
    # E.g.,
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

# Function to enable Nginx config (create symlink)
enable_nginx_config() {
    local domain="$1"
    local available_path="${NGINX_SITES_AVAILABLE}/${domain}.conf"
    local enabled_path="${NGINX_SITES_ENABLED}/${domain}.conf"

    if [[ -f "$available_path" ]]; then
        if [[ -L "$enabled_path" ]]; then
            log_message "warning" "Nginx config for ${domain} already enabled. Updating symlink."
            rm -f "$enabled_path" # Remove old symlink to create new one if target changed
        fi
        ln -s "$available_path" "$enabled_path" || { log_message "error" "Failed to enable Nginx config for ${domain}. Check permissions."; return 1; }
        log_message "success" "Enabled Nginx config for ${domain}."
        return 0
    else
        log_message "error" "Nginx config file not found for ${domain} at ${available_path}. Cannot enable."
        return 1
    fi
}

# Function to disable and remove Nginx config
disable_nginx_config() {
    local domain="$1"
    local enabled_path="${NGINX_SITES_ENABLED}/${domain}.conf"
    local available_path="${NGINX_SITES_AVAILABLE}/${domain}.conf"

    if [[ -L "$enabled_path" ]]; then
        rm -f "$enabled_path" || { log_message "error" "Failed to remove Nginx enabled symlink for ${domain}."; }
        log_message "info" "Disabled Nginx config symlink for ${domain}."
    fi
    if [[ -f "$available_path" ]]; then
        rm -f "$available_path" || { log_message "error" "Failed to remove Nginx available config file for ${domain}."; }
        log_message "info" "Removed Nginx config file for ${domain}."
    fi
    return 0
}

# Function to apply Certbot for a domain
apply_certbot() {
    local domain="$1"
    log_message "info" "Attempting to get SSL certificate for ${domain}..."
    
    # Common Certbot flags
    local certbot_flags="--nginx -d \"${domain}\" --non-interactive --agree-tos --email \"${EMAIL_FOR_CERTBOT}\" --redirect --hsts --staple-ocsp"
    
    # Check if Certbot supports the --no-reuse-existing-projects flag
    # This is a robust way to handle older Certbot versions
    if certbot --help deploy | grep -q -- "--no-reuse-existing-projects"; then
        certbot_flags+=" --no-reuse-existing-projects"
    else
        log_message "warning" "Your Certbot version does not support --no-reuse-existing-projects. Proceeding without it."
    fi

    # Execute Certbot command
    # Using eval here is necessary because certbot_flags is a string that needs to be
    # parsed by the shell after variable expansion. Be cautious with user-supplied input
    # if you were building certbot_flags from untrusted sources, but here it's internal.
    eval "certbot $certbot_flags"
    
    if [[ $? -ne 0 ]]; then
        log_message "warning" "Certbot failed for ${domain}. This could be due to DNS propagation issues, firewall, or existing certificates. Please verify your DNS A record (pointing THIS VPS IP) is public and port 80/443 are open."
        log_message "warning" "The tunnel for ${domain} might still work over HTTP, but HTTPS will not be active without a certificate."
        return 1
    else
        log_message "success" "SSL certificate obtained and Nginx configured for HTTPS for ${domain}."
        return 0
    fi
}


# --- Main Menu Options ---

add_domain() {
    clear
    log_message "info" "--- Add New Subdomain Tunnel ---"
    read -rp "Enter the subdomain (e.g., ops.example.com): " subdomain
    subdomain=$(echo "$subdomain" | tr '[:upper:]' '[:lower:]' | xargs) # Convert to lowercase and trim whitespace

    if [[ -z "$subdomain" ]]; then
        log_message "error" "Subdomain cannot be empty."
        press_enter_to_continue
        return
    fi
    if ! is_valid_domain "$subdomain"; then
        log_message "error" "Invalid subdomain format. Please use a valid domain name (e.g., example.com or sub.example.com)."
        press_enter_to_continue
        return
    fi


    if [[ "${DOMAINS[$subdomain]}" ]]; then
        log_message "warning" "Subdomain '${subdomain}' already exists with IP: ${DOMAINS[$subdomain]}."
        read -rp "Do you want to update its main server IP? (y/N): " update_confirm
        if [[ "$update_confirm" != "y" && "$update_confirm" != "Y" ]]; then
            log_message "info" "Operation cancelled."
            press_enter_to_continue
            return
        fi
    fi

    read -rp "Enter the main server IP for ${subdomain}: " ip_address
    ip_address=$(echo "$ip_address" | xargs) # Trim whitespace

    if ! is_valid_ip "$ip_address"; then
        log_message "error" "Invalid IP address format. Please enter a valid IPv4 address (e.g., 192.168.1.1)."
        press_enter_to_continue
        return
    fi

    log_message "info" "Adding/Updating ${subdomain} pointing to ${ip_address}..."
    DOMAINS["$subdomain"]="$ip_address"
    save_domains

    # Ensure Nginx is running before generating config
    systemctl is-active --quiet nginx || { log_message "info" "Nginx not active, attempting to start..."; systemctl start nginx || { log_message "error" "Failed to start Nginx. Check its status."; press_enter_to_continue; return; } }

    generate_nginx_config "$subdomain" "$ip_address" && \
    enable_nginx_config "$subdomain" && \
    systemctl reload nginx && \
    log_message "success" "Nginx reloaded with initial HTTP config for ${subdomain}."

    # Attempt Certbot and update Nginx for HTTPS
    if apply_certbot "$subdomain"; then
        systemctl reload nginx && \
        log_message "success" "Final Nginx reload for ${subdomain} with HTTPS."
    else
        log_message "warning" "HTTPS setup for ${subdomain} might be incomplete. Please check logs and Cloudflare DNS."
    fi # This 'fi' was missing the '_' that was in the previous version, causing the error. Corrected.

    log_message "info" "--- IMPORTANT Cloudflare Steps ---"
    log_message "info" "1. In Cloudflare, if you have an existing record for '${subdomain}', ensure it's **proxied (orange cloud)** and points to your **main server's IP**."
    log_message "info" "2. Add a **SECOND A record** for '${subdomain}' with the following details:"
    log_message "info" "   - **Type:** A"
    log_message "info" "   - **Name:** '${subdomain}'"
    log_message "info" "   - **Content:** The IP address of **THIS Iran VPS**"
    log_message "info" "   - **Proxy status:** DISABLED (gray cloud) - This is CRITICAL for the tunnel to work!"
    log_message "info" "This setup ensures traffic from specific regions hits this VPS, while general traffic uses your main server via Cloudflare's proxy."
    
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

    # Input validation
    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
        log_message "error" "Invalid input. Please enter a number."
        press_enter_to_continue
        return
    fi

    if [[ "$choice" -eq 0 ]]; then
        log_message "info" "Returning to main menu."
        return
    fi

    if [[ "$choice" -ge 1 ]] && [[ "$choice" -le "${#domain_list[@]}" ]]; then
        local domain_to_delete="${domain_list[choice-1]}"
        read -rp "Are you sure you want to delete '${domain_to_delete}'? This will remove its Nginx config and Certbot certificate. (y/N): " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            log_message "info" "Deleting ${domain_to_delete}..."
            
            # Disable Nginx config first
            disable_nginx_config "$domain_to_delete"

            # Attempt to remove Certbot certificate if it exists
            log_message "info" "Attempting to remove Certbot certificate for ${domain_to_delete}..."
            certbot delete --non-interactive --cert-name "$domain_to_delete" &>/dev/null
            if [[ $? -eq 0 ]]; then
                log_message "success" "Certbot certificate for ${domain_to_delete} removed."
            else
                log_message "warning" "No Certbot certificate found or failed to remove for ${domain_to_delete}. This might be normal if it failed to issue initially."
            fi
            
            unset DOMAINS["$domain_to_delete"]
            save_domains
            
            systemctl reload nginx || log_message "error" "Failed to reload Nginx after deletion. Manual check needed."
            log_message "success" "Successfully deleted ${domain_to_delete}."
        else
            log_message "info" "Deletion cancelled."
        fi
    else
        log_message "error" "Invalid choice. Please enter a number from the list or 0."
    fi
    press_enter_to_continue
}

remove_all() {
    clear
    log_message "warning" "--- Remove Everything ---"
    read -rp "${RED}This will remove ALL Nginx configurations, ALL Certbot data, and ALL dependencies installed by this script. This action is irreversible. Are you absolutely sure you want to proceed? (type 'yes' to confirm):${NC} " confirm_full

    if [[ "$confirm_full" == "yes" ]]; then
        log_message "info" "Proceeding with complete removal..."

        # Stop and disable Nginx
        log_message "info" "Stopping and disabling Nginx service..."
        systemctl stop nginx &>/dev/null
        systemctl disable nginx &>/dev/null
        log_message "success" "Nginx stopped and disabled."

        # Remove all Nginx site configs and main conf
        log_message "info" "Removing Nginx site configurations and cache..."
        rm -rf "${NGINX_SITES_AVAILABLE}"/* &>/dev/null
        rm -rf "${NGINX_SITES_ENABLED}"/* &>/dev/null
        rm -f /etc/nginx/nginx.conf &>/dev/null
        rm -rf /var/cache/nginx &>/dev/null
        log_message "success" "Nginx site configurations and cache removed."

        # Remove Certbot certificates and data
        log_message "info" "Removing Certbot certificates and data..."
        certbot unregister --non-interactive || log_message "warning" "Certbot unregister failed or no account exists (might be normal if no certs were issued)."
        rm -rf /etc/letsencrypt &>/dev/null
        log_message "success" "Certbot data removed."

        # Remove config file and directory
        log_message "info" "Removing script configuration file and directory..."
        rm -rf "$CONFIG_DIR" &>/dev/null
        log_message "success" "Script configuration removed."

        # Remove installed packages
        log_message "info" "Attempting to remove Nginx and Certbot packages..."
        # Prioritize snap removal for certbot
        if command -v snap &>/dev/null && snap list | grep -q "certbot"; then
            snap remove --purge certbot || log_message "warning" "Failed to purge Certbot snap package."
        fi
        # Remove apt packages
        apt purge -y nginx certbot python3-certbot-nginx snapd &>/dev/null # Also try to purge snapd
        apt autoremove -y &>/dev/null
        log_message "success" "Dependencies purged."
        
        # Remove cron job for certbot renewal
        log_message "info" "Removing Certbot renewal cron job..."
        (crontab -l 2>/dev/null | grep -v 'certbot renew' | crontab -) &>/dev/null
        log_message "success" "Certbot renewal cron job removed."

        # Remove the script itself
        log_message "info" "Removing the script itself from /usr/local/bin/..."
        # Get the actual path of the currently executing script
        CURRENT_SCRIPT_PATH="$(readlink -f "$0")"
        if [[ "$CURRENT_SCRIPT_PATH" == "/usr/local/bin/${SCRIPT_NAME}" ]]; then
            rm -f "$CURRENT_SCRIPT_PATH" &>/dev/null
            log_message "success" "Script ${SCRIPT_NAME} removed."
        else
            log_message "warning" "Script not found at expected path /usr/local/bin/${SCRIPT_NAME}. It might be running from a temporary location."
            log_message "info" "You may need to manually remove any lingering copies."
        fi

        log_message "success" "All components installed by this script have been removed."
        log_message "info" "It is highly recommended to reboot your server now to ensure all changes take full effect: 'sudo reboot'"
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

# --- Self-Download and Re-execute Function ---
self_download_and_run() {
    local script_path="/usr/local/bin/${SCRIPT_NAME}"
    
    log_message "info" "Script not found locally or initiating first-time download. Downloading ${SCRIPT_NAME} from GitHub..."
    if command -v curl &>/dev/null; then
        curl -sL "$GITHUB_RAW_URL" -o "$script_path"
    elif command -v wget &>/dev/null; then
        wget -qO "$script_path" "$GITHUB_RAW_URL"
    else
        log_message "error" "Neither curl nor wget found. Please install one to download the script (e.g., sudo apt install curl)."
        exit 1
    fi
    
    if [[ $? -ne 0 || ! -f "$script_path" ]]; then
        log_message "error" "Failed to download ${SCRIPT_NAME} from GitHub. Check the URL and your network connection."
        exit 1
    fi
    chmod +x "$script_path"
    log_message "success" "${SCRIPT_NAME} downloaded to ${script_path} and made executable."
    
    log_message "info" "Re-executing the script from its permanent location..."
    exec "$script_path" # Transfer control to the newly downloaded script
}


# --- Main Execution Flow ---
check_root

# This block determines if the script is being run for the first time via curl/wget
# or if it's already installed locally and being run directly.
# The `exec "$script_path"` in `self_download_and_run` transfers control to the
# newly downloaded script, making `$(readlink -f "$0")` equal to `/usr/local/bin/${SCRIPT_NAME}`
# for the *subsequent* run of the downloaded script.

# Check if the script is being run as the installed version in /usr/local/bin
if [[ "$(readlink -f "$0")" == "/usr/local/bin/${SCRIPT_NAME}" ]]; then
    log_message "info" "Running installed script from /usr/local/bin/${SCRIPT_NAME}."
    load_domains || { log_message "error" "Failed to load domains. Exiting."; exit 1; }
    
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
    # This branch is for the *very first* execution via `curl | bash`
    # It calls the self-downloading process.
    self_download_and_run
fi
