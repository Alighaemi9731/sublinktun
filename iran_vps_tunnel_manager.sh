#!/bin/bash

# Configuration file for storing domains and IPs
CONFIG_DIR="/etc/nginx-tunnel-manager"
CONFIG_FILE="$CONFIG_DIR/domains.conf"
SCRIPT_NAME="tunnel_manager.sh"
SCRIPT_PATH="/usr/local/bin/$SCRIPT_NAME"
CERTBOT_EMAIL="your_email@example.com" # !!! IMPORTANT: Change this to your actual email address !!!

# --- Helper Functions ---

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to display a message and wait for user input
press_enter_to_continue() {
    echo -e "\nPress Enter to continue..."
    read -r
}

# Function to display error messages
error_message() {
    echo -e "\n\033[0;31mError: $1\033[0m" # Red color
}

# Function to display success messages
success_message() {
    echo -e "\n\033[0;32mSuccess: $1\033[0m" # Green color
}

# Function to display informational messages
info_message() {
    echo -e "\033[0;34mInfo: $1\033[0m" # Blue color
}

# Function to validate a domain name
is_valid_domain() {
    local domain="$1"
    [[ "$domain" =~ ^[a-zA-Z0-9.-]+$ ]] && ! [[ "$domain" =~ ^- ]] && ! [[ "$domain" =~ -$ ]] && ! [[ "$domain" =~ \.\. ]]
}

# Function to validate an IP address
is_valid_ip() {
    local ip="$1"
    [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]
    local IFS=.
    local i
    for i in $ip; do
        if ((i < 0 || i > 255)); then
            return 1
        fi
    done
    return 0
}

# Function to load domains from the config file
load_domains() {
    declare -gA DOMAINS
    DOMAINS=() # Clear existing domains
    if [[ -f "$CONFIG_FILE" ]]; then
        while IFS='=' read -r domain ip; do
            if [[ -n "$domain" && -n "$ip" ]]; then
                DOMAINS["$domain"]="$ip"
            fi
        done < "$CONFIG_FILE"
    fi
}

# Function to save domains to the config file
save_domains() {
    mkdir -p "$CONFIG_DIR"
    > "$CONFIG_FILE" # Clear the file before writing
    for domain in "${!DOMAINS[@]}"; do
        echo "$domain=${DOMAINS[$domain]}" >> "$CONFIG_FILE"
    done
}

# Function to restart Nginx
restart_nginx() {
    info_message "Testing Nginx configuration..."
    if ! nginx -t; then
        error_message "Nginx configuration test failed. Check logs for details."
        return 1
    fi
    info_message "Reloading Nginx..."
    systemctl reload nginx
    if [[ $? -eq 0 ]]; then
        success_message "Nginx reloaded successfully."
        return 0
    else
        error_message "Failed to reload Nginx. Check systemctl status nginx."
        return 1
    fi
}

# Function to configure Nginx for a domain
configure_nginx_domain() {
    local domain="$1"
    local origin_ip="$2"
    local conf_file="/etc/nginx/sites-available/${domain}.conf"

    cat > "$conf_file" <<EOL
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
        proxy_buffering on;
        proxy_cache_bypass \$http_pragma \$http_authorization;
        proxy_no_cache \$http_pragma \$http_authorization;
    }
}
EOL
    ln -sf "$conf_file" /etc/nginx/sites-enabled/
}

# Function to remove Nginx configuration for a domain
remove_nginx_domain() {
    local domain="$1"
    local conf_file="/etc/nginx/sites-available/${domain}.conf"
    
    if [[ -L "/etc/nginx/sites-enabled/${domain}.conf" ]]; then
        rm "/etc/nginx/sites-enabled/${domain}.conf"
        info_message "Removed symlink for ${domain}."
    fi
    
    if [[ -f "$conf_file" ]]; then
        rm "$conf_file"
        info_message "Removed Nginx configuration file for ${domain}."
    fi
}

# Function to obtain SSL certificate
get_ssl_certificate() {
    local domain="$1"
    info_message "Attempting to obtain SSL certificate for ${domain}..."
    if certbot --nginx -d "$domain" --non-interactive --agree-tos --email "$CERTBOT_EMAIL"; then
        success_message "SSL certificate obtained successfully for ${domain}."
        return 0
    else
        error_message "Failed to obtain SSL certificate for ${domain}. Please check Certbot logs."
        return 1
    fi
}

# Function to revoke SSL certificate (optional, usually delete is enough)
revoke_ssl_certificate() {
    local domain="$1"
    info_message "Revoking SSL certificate for ${domain}..."
    if certbot revoke --cert-name "$domain" --non-interactive; then
        success_message "SSL certificate revoked for ${domain}."
    else
        error_message "Failed to revoke SSL certificate for ${domain}. It might already be removed or an error occurred."
    fi
}

# Function to delete SSL certificate files
delete_ssl_certificate_files() {
    local domain="$1"
    info_message "Deleting SSL certificate files for ${domain}..."
    if certbot delete --cert-name "$domain" --non-interactive; then
        success_message "SSL certificate files deleted for ${domain}."
        return 0
    else
        error_message "Failed to delete SSL certificate files for ${domain}. It might already be removed or an error occurred."
        return 1 # <--- THIS LINE WAS MISSING IN THE PREVIOUS VERSION
    fi
}

# --- Main Script Functions ---

# Function for initial setup
initial_setup() {
    info_message "Starting initial setup..."

    # Check for root privileges
    if [[ "$EUID" -ne 0 ]]; then
        error_message "Please run this script with root privileges (sudo)."
        exit 1
    fi

    # Update system and install requirements
    info_message "Updating system and installing required packages (nginx, certbot, python3-certbot-nginx)..."
    if ! apt update && apt upgrade -y; then
        error_message "Failed to update system."
        exit 1
    fi
    if ! apt install -y nginx certbot python3-certbot-nginx; then
        error_message "Failed to install required packages. Please check your internet connection and package repositories."
        exit 1
    fi
    success_message "System updated and required packages installed."

    # Create Nginx cache directory
    info_message "Setting up Nginx cache directory /var/cache/nginx..."
    mkdir -p /var/cache/nginx
    if ! chown -R www-data:www-data /var/cache/nginx; then
        error_message "Failed to set ownership for Nginx cache directory."
        exit 1
    fi
    success_message "Nginx cache directory setup complete."

    # Main Nginx config
    info_message "Writing main Nginx configuration to /etc/nginx/nginx.conf..."
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
    success_message "Main Nginx configuration written."

    # Ensure Nginx is running and enabled
    info_message "Ensuring Nginx service is enabled and running..."
    systemctl enable nginx
    systemctl start nginx
    if systemctl is-active --quiet nginx; then
        success_message "Nginx service is running."
    else
        error_message "Nginx service is not running. Please check 'systemctl status nginx'."
        exit 1
    fi

    # Set up certbot renewal cron job
    info_message "Setting up Certbot renewal cron job..."
    if ! (crontab -l 2>/dev/null | grep -Fq "/usr/bin/certbot renew --quiet"); then
        (crontab -l 2>/dev/null; echo "0 12 * * * /usr/bin/certbot renew --quiet") | crontab -
        success_message "Certbot renewal cron job added."
    else
        info_message "Certbot renewal cron job already exists."
    fi

    mkdir -p "$CONFIG_DIR"
    touch "$CONFIG_FILE"

    success_message "Initial setup complete! You can now add your subdomains."
    press_enter_to_continue
}

# Function to add a subdomain tunnel
add_subdomain() {
    load_domains
    local subdomain=""
    local origin_ip=""

    echo -e "\n--- Add New Subdomain Tunnel ---"
    while true; do
        read -rp "Enter the subdomain (e.g., my.example.com): " subdomain
        if ! is_valid_domain "$subdomain"; then
            error_message "Invalid subdomain format. Please try again."
        elif [[ "${DOMAINS[$subdomain]}" ]]; then
            error_message "This subdomain already exists. Please choose a different one or delete the existing one."
        else
            break
        fi
    done

    while true; do
        read -rp "Enter the IP address of your main server (e.g., 192.168.1.100): " origin_ip
        if ! is_valid_ip "$origin_ip"; then
            error_message "Invalid IP address format. Please try again."
        else
            break
        fi
    done

    info_message "Adding Nginx configuration for ${subdomain} pointing to ${origin_ip}..."
    configure_nginx_domain "$subdomain" "$origin_ip"

    if restart_nginx; then
        info_message "Nginx configuration applied. Now attempting to get SSL certificate."
        if get_ssl_certificate "$subdomain"; then
            DOMAINS["$subdomain"]="$origin_ip"
            save_domains
            success_message "Subdomain '${subdomain}' added and configured successfully with SSL!"
            echo -e "\n\033[0;33mIMPORTANT: Please go to your DNS provider (e.g., Cloudflare) for '${subdomain}' and do the following:\033[0m"
            echo -e "1. \033[0;33mKeep any existing proxied (orange cloud) record pointing to your main server (${origin_ip}).\033[0m"
            echo -e "2. \033[0;33mAdd a SECOND A record for '${subdomain}' that points to THIS VPS's IP address and ensure proxy is DISABLED (gray cloud).\033[0m"
        else
            error_message "Failed to obtain SSL certificate. Removing Nginx config and reverting changes."
            remove_nginx_domain "$subdomain"
            restart_nginx
        fi
    else
        error_message "Failed to apply Nginx configuration for ${subdomain}. Rolling back."
        remove_nginx_domain "$subdomain"
        restart_nginx
    fi
    press_enter_to_continue
}

# Function to list and delete a subdomain tunnel
delete_subdomain() {
    load_domains
    if [[ ${#DOMAINS[@]} -eq 0 ]]; then
        info_message "No subdomains configured yet."
        press_enter_to_continue
        return
    fi

    echo -e "\n--- Delete Subdomain Tunnel ---"
    echo "Current configured subdomains:"
    local i=1
    local domain_array=()
    for domain in "${!DOMAINS[@]}"; do
        domain_array+=("$domain")
        echo "  $i) $domain -> ${DOMAINS[$domain]}"
        ((i++))
    done

    local selection
    while true; do
        read -rp "Enter the number of the subdomain to delete (or 0 to cancel): " selection
        if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 0 && selection < i )); then
            break
        else
            error_message "Invalid selection. Please enter a valid number."
        fi
    done

    if [[ "$selection" -eq 0 ]]; then
        info_message "Deletion cancelled."
        press_enter_to_continue
        return
    fi

    local domain_to_delete="${domain_array[selection-1]}"
    read -rp "Are you sure you want to delete '${domain_to_delete}'? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        info_message "Deletion cancelled."
        press_enter_to_continue
        return
    fi

    info_message "Deleting Nginx configuration for ${domain_to_delete}..."
    remove_nginx_domain "$domain_to_delete"

    info_message "Attempting to delete SSL certificate for ${domain_to_delete}..."
    delete_ssl_certificate_files "$domain_to_delete"

    if restart_nginx; then
        unset DOMAINS["$domain_to_delete"]
        save_domains
        success_message "Subdomain '${domain_to_delete}' and its Nginx configuration removed successfully."
        echo -e "\n\033[0;33mIMPORTANT: Remember to remove the A record for '${domain_to_delete}' pointing to THIS VPS's IP address from your DNS provider!\033[0m"
    else
        error_message "Failed to restart Nginx after deletion. Manual intervention might be required."
        echo -e "You may need to manually remove /etc/nginx/sites-available/${domain_to_delete}.conf and its symlink, and restart Nginx."
    fi
    press_enter_to_continue
}

# Function to show current tunnels
list_subdomains() {
    load_domains
    echo -e "\n--- Current Subdomain Tunnels ---"
    if [[ ${#DOMAINS[@]} -eq 0 ]]; then
        info_message "No subdomains configured yet."
    else
        echo "Subdomain -> Main Server IP"
        echo "--------------------------"
        for domain in "${!DOMAINS[@]}"; do
            echo "$domain -> ${DOMAINS[$domain]}"
        done
    fi
    press_enter_to_continue
}

# Function to remove everything
remove_everything() {
    echo -e "\n--- Remove All Script Changes ---"
    read -rp "WARNING: This will remove Nginx, Certbot, all configurations, and data created by this script. Are you absolutely sure? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        info_message "Operation cancelled."
        press_enter_to_continue
        return
    fi

    read -rp "This is irreversible. Confirm again by typing 'YES': " final_confirm
    if [[ "$final_confirm" != "YES" ]]; then
        info_message "Operation cancelled."
        press_enter_to_continue
        return
    fi

    info_message "Stopping Nginx service..."
    systemctl stop nginx

    info_message "Removing all Nginx site configurations and symlinks..."
    for domain in "${!DOMAINS[@]}"; do
        remove_nginx_domain "$domain"
    done

    info_message "Deleting all Certbot certificates managed by this script..."
    # Get a list of certificates issued by Certbot
    certbot certificates | grep '^\s*Name:' | awk '{print $2}' | while read -r cert_name; do
        if certbot delete --cert-name "$cert_name" --non-interactive; then
            info_message "Deleted certificate: $cert_name"
        else
            error_message "Could not delete certificate: $cert_name. Manual cleanup may be required."
        fi
    done

    info_message "Removing Nginx cache directory..."
    rm -rf /var/cache/nginx

    info_message "Restoring default Nginx configuration..."
    apt purge -y nginx nginx-common nginx-full
    apt autoremove -y

    info_message "Purging Certbot packages..."
    apt purge -y certbot python3-certbot-nginx
    apt autoremove -y

    info_message "Removing script configuration directory and data..."
    rm -rf "$CONFIG_DIR"

    info_message "Removing Certbot cron job..."
    (crontab -l 2>/dev/null | grep -v "/usr/bin/certbot renew --quiet") | crontab -

    info_message "Removing the script itself..."
    if [[ -f "$SCRIPT_PATH" ]]; then
        rm "$SCRIPT_PATH"
    fi

    success_message "All traces of the Nginx tunnel manager script have been removed."
    echo -e "\n\033[0;31mYou will need to manually reboot your VPS for all changes to take full effect if Nginx was heavily modified.\033[0m"
    exit 0
}

# --- Main Menu ---

show_menu() {
    clear
    echo "-------------------------------------"
    echo "  Nginx Subdomain Tunnel Manager"
    echo "-------------------------------------"
    echo "1. Add new subdomain tunnel"
    echo "2. List and delete subdomain tunnel"
    echo "3. Show current subdomain tunnels"
    echo "4. Remove everything this script has done"
    echo "5. Exit"
    echo "-------------------------------------"
    read -rp "Enter your choice: " choice
}

# --- Main Logic ---

# Check if the script is running for the first time or needs re-downloading
if [[ ! -f "$SCRIPT_PATH" || "$1" == "--reinstall" ]]; then
    info_message "First run or reinstalling. Performing initial setup..."
    initial_setup
else
    # If the script is already downloaded, load domains and proceed to menu
    info_message "Script found at $SCRIPT_PATH. Launching menu."
    load_domains
fi

while true; do
    show_menu
    case "$choice" in
        1) add_subdomain ;;
        2) delete_subdomain ;;
        3) list_subdomains ;;
        4) remove_everything ;;
        5) info_message "Exiting script. Goodbye!"; exit 0 ;;
        *) error_message "Invalid option. Please try again."; press_enter_to_continue ;;
    esac
done
