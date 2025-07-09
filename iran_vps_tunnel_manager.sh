#!/bin/bash

#================================================================================#
#            Nginx Tunnel Manager - by Gemini @ Google (for Alighaemi)           #
#                                                                                #
#  A script to easily add, remove, and manage Nginx reverse proxy tunnels        #
#  with automated SSL certificate generation via Certbot.                        #
#                                                                                #
#================================================================================#

# --- Configuration ---
# File to store the mapping of subdomains to their origin server IPs.
CONFIG_FILE="/etc/nginx/tunnel_manager.conf"
# User email for Let's Encrypt SSL notifications. Will be prompted on first run.
EMAIL_FILE="/etc/nginx/certbot_email.conf"
MY_EMAIL=""

# --- Colors for UI ---
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_CYAN='\033[0;36m'

# --- Helper Functions ---
function print_success() {
    echo -e "${C_GREEN}[SUCCESS]${C_RESET} $1"
}

function print_error() {
    echo -e "${C_RED}[ERROR]${C_RESET} $1"
}

function print_info() {
    echo -e "${C_CYAN}[INFO]${C_RESET} $1"
}

function check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_error "This script must be run as root. Please use 'sudo'."
        exit 1
    fi
}

# --- Core Logic ---

# Function to run the initial setup and install required packages.
function initial_setup() {
    if command -v nginx &> /dev/null && command -v certbot &> /dev/null; then
        print_info "Nginx and Certbot are already installed."
        return
    fi
    
    print_info "Updating system and installing required packages (Nginx, Certbot)..."
    apt update && apt upgrade -y
    if ! apt install -y nginx certbot python3-certbot-nginx; then
        print_error "Failed to install required packages. Please check your system's package manager."
        exit 1
    fi

    print_info "Creating Nginx cache directory..."
    mkdir -p /var/cache/nginx
    chown -R www-data:www-data /var/cache/nginx

    print_info "Writing main Nginx configuration..."
    cat > /etc/nginx/nginx.conf <<EOL
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

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
    
    print_info "Setting up Certbot renewal cron job..."
    (crontab -l 2>/dev/null | grep -v 'certbot renew'; echo "0 4 * * * /usr/bin/certbot renew --quiet") | crontab -

    systemctl enable nginx
    systemctl start nginx
    print_success "Initial setup complete."
}

# Function to add a new subdomain tunnel.
function add_domain() {
    clear
    echo -e "${C_BLUE}--- Add New Subdomain Tunnel ---${C_RESET}"
    
    read -p "Enter the subdomain (e.g., sub.example.com): " subdomain
    if [[ -z "$subdomain" ]]; then
        print_error "Subdomain cannot be empty."
        return
    fi

    read -p "Enter the main server's IP address for this subdomain: " server_ip
    if [[ -z "$server_ip" ]]; then
        print_error "Server IP cannot be empty."
        return
    fi
    
    # Check if domain already exists
    if grep -q "^${subdomain} " "${CONFIG_FILE}"; then
        print_error "This subdomain is already configured."
        return
    fi

    print_info "Creating Nginx configuration for ${subdomain}..."
    
    cat > "/etc/nginx/sites-available/${subdomain}.conf" <<EOL
server {
    listen 80;
    listen [::]:80;
    server_name ${subdomain};

    location / {
        proxy_pass http://${server_ip}; # We will use HTTP here and let Certbot handle HTTPS redirect
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # Caching configuration
        proxy_cache my_cache;
        proxy_cache_valid 200 302 60m;
        proxy_cache_valid 404 1m;
        proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
        add_header X-Proxy-Cache \$upstream_cache_status;
    }
}
EOL

    ln -s "/etc/nginx/sites-available/${subdomain}.conf" "/etc/nginx/sites-enabled/"

    print_info "Testing Nginx configuration..."
    if ! nginx -t; then
        print_error "Nginx configuration test failed. Reverting changes."
        rm "/etc/nginx/sites-available/${subdomain}.conf"
        rm "/etc/nginx/sites-enabled/${subdomain}"
        nginx -t
        systemctl reload nginx
        return
    fi

    print_info "Reloading Nginx..."
    systemctl reload nginx

    print_info "Requesting SSL certificate from Let's Encrypt..."
    if ! certbot --nginx --non-interactive --agree-tos --email "${MY_EMAIL}" -d "${subdomain}" --redirect; then
         print_error "Certbot failed to obtain an SSL certificate. The site is currently HTTP only."
         print_error "Please check DNS records are pointing to this server and try again."
    else
        print_success "SSL certificate obtained and configured successfully."
    fi

    echo "${subdomain} ${server_ip}" >> "${CONFIG_FILE}"
    print_success "Tunnel for ${subdomain} -> ${server_ip} has been created."
    read -n 1 -s -r -p "Press any key to return to the menu..."
}

# Function to show and allow deletion of a domain.
function delete_domain() {
    clear
    echo -e "${C_YELLOW}--- Delete a Subdomain Tunnel ---${C_RESET}"
    
    if [ ! -s "${CONFIG_FILE}" ]; then
        print_error "No domains have been configured yet."
        read -n 1 -s -r -p "Press any key to return to the menu..."
        return
    fi

    mapfile -t domains < "${CONFIG_FILE}"
    
    echo "Select the domain to delete:"
    i=1
    for domain_entry in "${domains[@]}"; do
        echo "  $i) $domain_entry"
        i=$((i+1))
    done
    echo "  0) Back to Main Menu"
    
    read -p "Enter your choice [0-$((${#domains[@]}))]: " choice

    if [[ "$choice" -eq 0 ]]; then
        return
    fi

    if [[ "$choice" -gt 0 && "$choice" -le ${#domains[@]} ]]; then
        selection_index=$((choice-1))
        domain_to_delete=$(echo "${domains[$selection_index]}" | awk '{print $1}')
        
        read -p "Are you sure you want to delete the tunnel for ${domain_to_delete}? [y/N]: " confirm
        if [[ "${confirm,,}" != "y" ]]; then
            print_info "Deletion cancelled."
            return
        fi

        print_info "Deleting configuration for ${domain_to_delete}..."
        rm -f "/etc/nginx/sites-available/${domain_to_delete}.conf"
        rm -f "/etc/nginx/sites-enabled/${domain_to_delete}"

        # Use a temporary file to remove the line from the config
        grep -v "^${domain_to_delete} " "${CONFIG_FILE}" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"

        print_info "Testing and reloading Nginx..."
        nginx -t && systemctl reload nginx
        
        print_success "Tunnel for ${domain_to_delete} has been successfully deleted."
        print_info "Note: The SSL certificate will be pruned on the next Certbot renewal."

    else
        print_error "Invalid choice."
    fi
    read -n 1 -s -r -p "Press any key to return to the menu..."
}

# Function to completely remove everything the script has done.
function uninstall_script() {
    clear
    echo -e "${C_RED}--- UNINSTALL AND REMOVE EVERYTHING ---${C_RESET}"
    read -p "WARNING: This will delete ALL tunnels, Nginx configs, Certbot certs, and uninstall packages. This is IRREVERSIBLE. Are you absolutely sure? [y/N]: " confirm
    if [[ "${confirm,,}" != "y" ]]; then
        print_info "Uninstall cancelled."
        return
    fi

    print_info "Deleting all configured tunnels..."
    if [ -f "${CONFIG_FILE}" ]; then
        while read -r subdomain server_ip; do
            print_info "Removing ${subdomain}..."
            rm -f "/etc/nginx/sites-available/${subdomain}.conf"
            rm -f "/etc/nginx/sites-enabled/${subdomain}"
        done < "${CONFIG_FILE}"
    fi
    
    print_info "Purging Nginx and Certbot packages..."
    systemctl stop nginx
    apt-get purge --auto-remove -y nginx nginx-common certbot python3-certbot-nginx

    print_info "Deleting all remaining configuration and log files..."
    rm -rf /etc/nginx
    rm -rf /var/log/nginx
    rm -rf /var/cache/nginx
    rm -rf /etc/letsencrypt

    print_info "Removing Certbot cron job..."
    crontab -l | grep -v 'certbot renew' | crontab -

    print_info "Deleting this manager script..."
    rm -f /usr/local/bin/iran-tunnel-manager

    print_success "Uninstallation complete. The system is now clean of this script's changes."
    exit 0
}

# Function to display the main menu.
function main_menu() {
    while true; do
        clear
        echo -e "${C_CYAN}=======================================${C_RESET}"
        echo -e "${C_BLUE}  Iran VPS Nginx Tunnel Manager Menu   ${C_RESET}"
        echo -e "${C_CYAN}=======================================${C_RESET}"
        echo
        echo -e "${C_GREEN}   1. Add New Subdomain Tunnel${C_RESET}"
        echo -e "${C_YELLOW}   2. Delete a Subdomain Tunnel${C_RESET}"
        echo -e "${C_RED}   3. Uninstall Everything${C_RESET}"
        echo "   4. Exit"
        echo
        echo "---------------------------------------"
        echo -e "${C_CYAN}Configured Tunnels:${C_RESET}"
        if [ -s "${CONFIG_FILE}" ]; then
            cat -n "${CONFIG_FILE}"
        else
            echo "   No tunnels configured yet."
        fi
        echo "---------------------------------------"
        
        read -p "Enter your choice [1-4]: " choice
        
        case $choice in
            1) add_domain ;;
            2) delete_domain ;;
            3) uninstall_script ;;
            4) clear; exit 0 ;;
            *) print_error "Invalid option. Please try again." ; read -n 1 -s -r -p "" ;;
        esac
    done
}


# --- Main Execution ---
check_root
initial_setup

# Create config files if they don't exist
touch "${CONFIG_FILE}"

# Get user email for Certbot if not set
if [ ! -f "$EMAIL_FILE" ]; then
    read -p "Please enter your email address (for SSL certificate notifications): " user_email
    echo "$user_email" > "$EMAIL_FILE"
    MY_EMAIL=$user_email
else
    MY_EMAIL=$(cat "$EMAIL_FILE")
fi

main_menu
