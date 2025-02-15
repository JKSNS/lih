#!/bin/bash
# Usage: ./harden.sh [option]

###################### GLOBALS ######################
LOG='/var/log/ccdc/harden.log'
GITHUB_URL="https://raw.githubusercontent.com/BYU-CCDC/public-ccdc-resources/refs/heads/main"
pm=""
sudo_group=""
ccdc_users=( "ccdcuser1" "ccdcuser2" )
debug="false"
#####################################################

##################### FUNCTIONS #####################
# Prints text in a banner
# Arguments:
#   $1: Text to print
function print_banner {
    echo
    echo "#######################################"
    echo "#"
    echo "#   $1"
    echo "#"
    echo "#######################################"
    echo
}

function debug_print {
    if [ "$debug" == "true" ]; then
        echo -n "DEBUG: "
        for arg in "$@"; do
            echo -n "$arg"
        done
        echo -e "\n"
    fi
}

function get_input_string {
    read -r -p "$1" input
    echo "$input"
}

function get_silent_input_string {
    read -r -s -p "$1" input
    echo "$input"
}

function get_input_list {
    local input_list=()

    while [ "$continue" != "false" ]; do
        input=$(get_input_string "Enter input: (one entry per line; hit enter to continue): ")
        if [ "$input" == "" ]; then
            continue="false"
        else
            input_list+=("$input")
        fi
    done

    # Return the list by printing it
    # Note: Bash functions can't return arrays directly, but we can print them
    echo "${input_list[@]}"
}

function exclude_users {
    users="$@"
    input=$(get_input_list)
    for item in $input; do
        users+=("$item")
    done
    echo "${users[@]}"
}

function get_users {
    awk_string=$1
    exclude_users=$(sed -e 's/ /\\|/g' <<< $2)
    users=$(awk -F ':' "$awk_string" /etc/passwd)
    filtered=$(echo "$users" | grep -v -e $exclude_users)
    readarray -t results <<< $filtered
    echo "${results[@]}"
}

function detect_system_info {
    print_banner "Detecting system info"
    echo "[*] Detecting package manager"

    sudo which apt-get &> /dev/null
    apt=$?
    sudo which dnf &> /dev/null
    dnf=$?
    sudo which zypper &> /dev/null
    zypper=$?
    sudo which yum &> /dev/null
    yum=$?

    if [ $apt == 0 ]; then
        echo "[*] apt/apt-get detected (Debian-based OS)"
        echo "[*] Updating package list"
        sudo apt-get update
        pm="apt-get"
    elif [ $dnf == 0 ]; then
        echo "[*] dnf detected (Fedora-based OS)"
        pm="dnf"
    elif [ $zypper == 0 ]; then
        echo "[*] zypper detected (OpenSUSE-based OS)"
        pm="zypper"
    elif [ $yum == 0 ]; then
        echo "[*] yum detected (RHEL-based OS)"
        pm="yum"
    else
        echo "[X] ERROR: Could not detect package manager"
        exit 1
    fi

    echo "[*] Detecting sudo group"

    groups=$(compgen -g)
    if echo "$groups" | grep -q '^sudo$'; then
        echo '[*] sudo group detected'
        sudo_group='sudo'
    elif echo "$groups" | grep -q '^wheel$'; then
        echo '[*] wheel group detected'
        sudo_group='wheel'
    else
        echo '[X] ERROR: could not detect sudo group'
	exit 1
    fi
}

function install_prereqs {
    print_banner "Installing prerequisites"
    # TODO: install a syslog daemon for Splunk?
    # Needed for both hardening and Splunk installlation
    sudo $pm install -y zip unzip wget curl acl
}

function create_ccdc_users {
    print_banner "Creating ccdc users"
    for user in "${ccdc_users[@]}"; do
        if id "$user" &>/dev/null; then
            echo "[*] $user already exists. Skipping..."
        else
            echo "[*] $user not found. Attempting to create..."
            if [ -f "/bin/bash" ]; then
                sudo useradd -m -s /bin/bash "$user"
            elif [ -f "/bin/sh" ]; then
                sudo useradd -m -s /bin/sh "$user"
            else
                echo "[X] ERROR: Could not find valid shell"
                exit 1
            fi
            
            echo "[*] Enter the new password for $user:"
            while true; do
                password=""
                confirm_password=""

                # Ask for password
                password=$(get_silent_input_string "Enter password: ")
                echo

                # Confirm password
                confirm_password=$(get_silent_input_string "Confirm password: ")
                echo

                if [ "$password" != "$confirm_password" ]; then
                    echo "Passwords do not match. Please retry."
                    continue
                fi

                if ! echo "$user:$password" | sudo chpasswd; then
                    echo "[X] ERROR: Failed to set password for $user"
                else
                    echo "[*] Password for $user has been set."
                    break
                fi
            done

            if [ "$user" == "ccdcuser1" ]; then
                echo "[*] Adding to $sudo_group group"
                sudo usermod -aG $sudo_group "$user"
            fi
        fi
        echo
    done
}

function change_passwords {
    print_banner "Changing user passwords"

    exclusions=("${ccdc_users[@]}")
    echo "[*] Currently excluded users: ${exclusions[*]}"
    echo "[*] Would you like to exclude any additional users?"
    option=$(get_input_string "(y/N): ")
    if [ "$option" == "y" ]; then
        exclusions=$(exclude_users "${exclusions[@]}")
    fi

    # if sudo [ -e "/etc/centos-release" ] ; then
    #     # CentOS starts numbering at 500
    #     targets=$(get_users '$3 >= 500 && $1 != "nobody" {print $1}' "${exclusions[*]}")
    # else
    #     # Otherwise 1000
    #     targets=$(get_users '$3 >= 1000 && $1 != "nobody" {print $1}' "${exclusions[*]}")
    # fi
    targets=$(get_users '$1 != "nobody" {print $1}' "${exclusions[*]}")

    echo "[*] Enter the new password to be used for all users."
    while true; do
        password=""
        confirm_password=""

        # Ask for password
        password=$(get_silent_input_string "Enter password: ")
        echo

        # Confirm password
        confirm_password=$(get_silent_input_string "Confirm password: ")
        echo

        if [ "$password" != "$confirm_password" ]; then
            echo "Passwords do not match. Please retry."
        else
            break
        fi
    done

    echo

    echo "[*] Changing passwords..."
    for user in $targets; do
        if ! echo "$user:$password" | sudo chpasswd; then
            echo "[X] ERROR: Failed to change password for $user"
        else
            echo "[*] Password for $user has been changed."
        fi
    done
}

function disable_users {
    print_banner "Disabling users"

    nologin_shell=""
    if [ -f /usr/sbin/nologin ]; then
        nologin_shell="/usr/sbin/nologin"
    elif [ -f /sbin/nologin ]; then
        nologin_shell="/sbin/nologin"
    else
        nologin_shell="/bin/false"
    fi

    exclusions=("${ccdc_users[@]}")
    exclusions+=("root")
    echo "[*] Currently excluded users: ${exclusions[*]}"
    echo "[*] Would you like to exclude any additional users?"
    option=$(get_input_string "(y/N): ")
    if [ "$option" == "y" ]; then
        exclusions=$(exclude_users "${exclusions[@]}")
    fi
    targets=$(get_users '/\/bash$|\/sh$|\/ash$|\/zsh$/{print $1}' "${exclusions[*]}")

    echo

    echo "[*] Disabling users..."
    for user in $targets; do
        sudo usermod -s "$nologin_shell" "$user"
        echo "[*] Set shell for $user to $nologin_shell"
    done
}

function remove_sudoers {
    print_banner "Removing sudoers"
    echo "[*] Removing users from the $sudo_group group"
    
    exclusions=("ccdcuser1")
    echo "[*] Currently excluded users: ${exclusions[*]}"
    echo "[*] Would you like to exclude any additional users?"
    option=$(get_input_string "(y/N): ")
    if [ "$option" == "y" ]; then
        exclusions=$(exclude_users "${exclusions[@]}")
    fi
    targets=$(get_users '{print $1}' "${exclusions[*]}")

    echo

    echo "[*] Removing sudo users..."
    for user in $targets; do
        if groups "$user" | grep -q "$sudo_group"; then
            echo "[*] Removing $user from $sudo_group group"
            sudo gpasswd -d "$user" "$sudo_group"
        fi
    done
}

function disable_other_firewalls {
    print_banner "Disabling existing firewalls"
    if sudo command -v firewalld &>/dev/null; then
        echo "[*] disabling firewalld"
        sudo systemctl stop firewalld
        sudo systemctl disable firewalld
    fi
    # elif sudo command -v ufw &>/dev/null; then
    #     echo "[*] disabling ufw"
    #     sudo ufw disable
    # fi

    # Some systems may also have iptables as backend
    # if sudo command -v iptables &>/dev/null; then
    #     echo "[*] clearing iptables rules"
    #     sudo iptables -F
    # fi
}

########################################################################
# FUNCTION: setup_ufw
# Configures UFW firewall rules.
function setup_ufw {
    print_banner "Configuring ufw"

    sudo $pm install -y ufw
    sudo which ufw &> /dev/null
    if [ $? == 0 ]; then
        echo -e "[*] Package ufw installed successfully\n"
        echo "[*] Which ports should be opened for incoming traffic?"
        echo "      WARNING: Do NOT forget to add 22/SSH if needed- please don't accidentally lock yourself out of the system!"
        sudo ufw --force disable
        sudo ufw --force reset
        ports=$(get_input_list)
        for port in $ports; do
            sudo ufw allow "$port"
            echo "[*] Rule added for port $port"
        done
        sudo ufw logging on
        sudo ufw --force enable
    else
        echo "[X] ERROR: Package ufw failed to install. Firewall will need to be configured manually"
    fi
}

########################################################################
# FUNCTION: setup_custom_iptables
# This function writes the entire DSU dual-mode IPtables/awk script to a
# temporary file, executes it (which flushes existing rules and builds the
# base ruleset), and then cleans up. After that, it offers the option to
# enter an extended iptables management menu.
function setup_custom_iptables {
    print_banner "Configuring iptables (Custom Script)"
    
    echo "Select your DNS server option:"
    echo "  1) Use Cloudflare DNS servers (1.1.1.1, 1.0.0.1)"
    echo "  2) Use default gateway/router as your DNS server"
    echo "  3) Use default DNS servers (192.168.XXX.1, 192.168.XXX.2)"
    dns_choice=$(get_input_string "Enter your choice [1-3]: ")
    if [[ "$dns_choice" == "1" ]]; then
        dns_value="1.1.1.1 1.0.0.1"
    elif [[ "$dns_choice" == "2" ]]; then
        default_gateway=$(ip route | awk '/default/ {print $3; exit}')
        if [[ -z "$default_gateway" ]]; then
            echo "[X] Could not determine default gateway. Using fallback DNS servers."
            dns_value="192.168.XXX.1 192.168.XXX.2"
        else
            dns_value="$default_gateway"
        fi
    else
        dns_value="192.168.XXX.1 192.168.XXX.2"
    fi

    # Create a temporary file for the DSU script
    tmpfile=$(mktemp /tmp/iptables_script.XXXXXX)
    
    # Write the dual-mode script into the temporary file using a placeholder for DNS_SERVERS
    cat <<'EOF' > "$tmpfile"
#!/bin/bash
# This is a dual-mode script: valid as both a Bash script and an AWK script.
# Its purpose is to run as an AWK script fed by the output of "ss -napH4".

#region bash
sh -c "ss -napH4 | awk -f $BASH_SOURCE" {0..0}
"exit" {0..0}
#endregion bash

# Tested ss options: napOH4, napH4

# Configuration
BEGIN {
  UNRESTRICTED_SUBNETS = "10.128.XXX.0/24";
  EXTERNAL_SUBNET = "10.120.XXX.0/24";  # UNUSED
  DNS_SERVERS = "##DNS_SERVERS##";
  IPTABLES_CMD = "iptables";
  DEFAULT_INPUT_CHAIN = "INPUT";
  DEFAULT_OUTPUT_CHAIN = "OUTPUT";
  LOG_LEVEL = 2;
  SKIP_PROMPT = 0;
  INBOUND_CONNECTION_TYPES = "LISTEN";
  OUTBOUND_CONNECTION_TYPES = "ESTAB";
  INBOUND_PORT_WHITELIST  = "21 22 80 443 53";
  OUTBOUND_PORT_WHITELIST = INBOUND_PORT_WHITELIST;
  COLORED_OUTPUT = 1;
}

function keyify(arr) {
  for(i in arr) arr[arr[i]] = 1;
}

BEGIN {
  split(INBOUND_CONNECTION_TYPES, INBOUND_CONNECTION_TYPES_ARRAY);
  keyify(INBOUND_CONNECTION_TYPES_ARRAY);
  split(OUTBOUND_CONNECTION_TYPES, OUTBOUND_CONNECTION_TYPES_ARRAY);
  keyify(OUTBOUND_CONNECTION_TYPES_ARRAY);
  split(INBOUND_PORT_WHITELIST, INBOUND_PORT_WHITELIST_ARRAY);
  keyify(INBOUND_PORT_WHITELIST_ARRAY);
  split(OUTBOUND_PORT_WHITELIST, OUTBOUND_PORT_WHITELIST_ARRAY);
  keyify(OUTBOUND_PORT_WHITELIST_ARRAY);
  delete COLORS[0];
  COLORS["black"]         = 30;
  COLORS["red"]           = 31;
  COLORS["green"]         = 32;
  COLORS["yellow"]        = 33;
  COLORS["blue"]          = 34;
  COLORS["magenta"]       = 35;
  COLORS["cyan"]          = 36;
  COLORS["white"]         = 37;
  COLORS["default"]       = 39;
  COLORS["gray"]          = 90;
  COLORS["brightRed"]     = 91;
  COLORS["brightGreen"]   = 92;
  COLORS["brightYellow"]  = 93;
  COLORS["brightBlue"]    = 94;
  COLORS["brightMagenta"] = 95;
  COLORS["brightCyan"]    = 96;
  COLORS["brightWhite"]   = 97;
  delete LOG_LEVEL_COLORS[0];
  LOG_LEVEL_COLORS["DEBUG"]   = "magenta";
  LOG_LEVEL_COLORS["INFO"]    = "cyan";
  LOG_LEVEL_COLORS["WARNING"] = "yellow";
  LOG_LEVEL_COLORS["ERROR"]   = "red";
  delete LOG_LEVEL_NAMES[0];
  LOG_LEVEL_NAMES["DEBUG"]   = 1;
  LOG_LEVEL_NAMES["INFO"]    = 2;
  LOG_LEVEL_NAMES["WARNING"] = 3;
  LOG_LEVEL_NAMES["ERROR"]   = 4;
}

function setColor(color) {
  if(!COLORED_OUTPUT)
    return "";
  else if(color == "")
    return "\033[39m";
  else
    return sprintf("\033[%dm", COLORS[color]);
}

function colored(color, message) {
  return setColor(color) message setColor();
}

function printLog(level, message) {
  if(LOG_LEVEL_NAMES[level] < LOG_LEVEL) return;
  printf("%*s: %s\n", COLORED_OUTPUT ? 17 : 7, colored(LOG_LEVEL_COLORS[level], level), message) > "/dev/tty";
}

function formatPort(port, proto, name) {
  return colored("yellow", sprintf("%5d", port)) "/" proto " (" colored("blue", name) ")";
}

BEGIN {
  "tty" | getline isTTY;
  if(isTTY != "not a tty")
    printLog("WARNING", "TTY stdin detected. This script is designed to take the output from `ss -napOH4`");
  if(!SKIP_PROMPT) {
    print(colored("red", "WARNING") ": Existing rules for the " DEFAULT_INPUT_CHAIN " and " DEFAULT_OUTPUT_CHAIN " chains will be flushed!\nPress RETURN to continue.") > "/dev/tty";
    getline < "/dev/tty";
  }
  printLog("INFO", "Flushing " DEFAULT_INPUT_CHAIN);
  print(IPTABLES_CMD, "-F", DEFAULT_INPUT_CHAIN);
  printLog("INFO", "Flushing " DEFAULT_OUTPUT_CHAIN);
  print(IPTABLES_CMD, "-F", DEFAULT_OUTPUT_CHAIN);
  printLog("INFO", "Accepting loopback traffic on " DEFAULT_INPUT_CHAIN);
  print(IPTABLES_CMD, "-A", DEFAULT_INPUT_CHAIN, "-i lo -j ACCEPT");
  printLog("INFO", "Accepting loopback traffic on " DEFAULT_OUTPUT_CHAIN);
  print(IPTABLES_CMD, "-A", DEFAULT_OUTPUT_CHAIN, "-o lo -j ACCEPT");
  printLog("INFO", "Enabling connection tracking on " DEFAULT_INPUT_CHAIN);
  print(IPTABLES_CMD, "-A", DEFAULT_INPUT_CHAIN, "-m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT");
  printLog("INFO", "Enabling connection tracking on " DEFAULT_OUTPUT_CHAIN);
  print(IPTABLES_CMD, "-A", DEFAULT_OUTPUT_CHAIN, "-m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT");
  printLog("INFO", "Accepting ICMP traffic from " DEFAULT_INPUT_CHAIN);
  print(IPTABLES_CMD, "-A", DEFAULT_INPUT_CHAIN, "-p icmp -j ACCEPT");
  
  # Static DNS rules: allow outbound UDP and TCP on port 53 for each DNS server.
  split(DNS_SERVERS, _DNS_SERVERS);
  for(server in _DNS_SERVERS) {
    printLog("INFO", "New outbound rule - " sprintf("%15s", _DNS_SERVERS[server]) ":" colored("yellow", sprintf("%5d", 53)) "/udp (" colored("blue", "DNS") ")");
    print(IPTABLES_CMD, "-A", DEFAULT_OUTPUT_CHAIN, "-p", "udp", "-m", "udp", "--dport", 53, "-d", _DNS_SERVERS[server], "-j", "ACCEPT");
  }
  for(server in _DNS_SERVERS) {
    printLog("INFO", "New outbound rule - " sprintf("%15s", _DNS_SERVERS[server]) ":" colored("yellow", sprintf("%5d", 53)) "/tcp (" colored("blue", "DNS") ")");
    print(IPTABLES_CMD, "-A", DEFAULT_OUTPUT_CHAIN, "-p", "tcp", "-m", "tcp", "--dport", 53, "-d", _DNS_SERVERS[server], "-j", "ACCEPT");
  }
  
  split(UNRESTRICTED_SUBNETS, _UNRESTRICTED_SUBNETS);
  for(subnet in _UNRESTRICTED_SUBNETS) {
    printLog("INFO", "New inbound rule - " sprintf("%18s", _UNRESTRICTED_SUBNETS[subnet]) " (" colored("blue", "unrestricted subnet") ")");
    print(IPTABLES_CMD, "-A", DEFAULT_INPUT_CHAIN, "-d", _UNRESTRICTED_SUBNETS[subnet], "-j", "ACCEPT");
  }
  delete INPUT_RULES[0];
  delete OUTPUT_RULES[0];
}

function extractIP(string) {
  if(match(string, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) {
    return substr(string, RSTART, RLENGTH);
  }
  return "";
}

{
  if(match($7, "\"[^\"]+\""))
    name = substr($7, RSTART+1, RLENGTH-2);
  else
    name = "";
  split($6, remote, ":");
  remoteIP = extractIP(remote[1]);
  if(remoteIP == "")
    printLog("WARNING", "Invalid remote IP for " colored("yellow", $6) " (" colored("blue", name) ")");
  if(remote[2] != "*" && (remote[2] < 1 || remote[2] > 65535))
    printLog("WARNING", "Invalid remote port for " colored("yellow", $6) " (" colored("blue", name) ")");
  split($5, local, ":");
  localIP = extractIP(local[1]);
  if(localIP == "")
    printLog("WARNING", "Invalid local IP for " colored("yellow", $5) " (" colored("blue", name) ")");
  if(local[2] != "*" && (local[2] < 1 || local[2] > 65535))
    printLog("WARNING", "Invalid local port for " colored("yellow", $5) " (" colored("blue", name) ")");
}

$2 in INBOUND_CONNECTION_TYPES_ARRAY {
  if(INPUT_RULES[local[2] "/" $1]) next;
  if(local[2] in INBOUND_PORT_WHITELIST_ARRAY == 0) {
    printLog("WARNING", "Inbound connection " formatPort(local[2], $1, name) " not in whitelist, skipping.");
    next;
  }
  if(name)
    comment = "-m comment --comment \"" name "\"";
  else
    comment = "";
  print(IPTABLES_CMD " -A " DEFAULT_INPUT_CHAIN " -p " $1 " -m " $1 " --dport " local[2] " " comment " -j ACCEPT");
  printLog("INFO", "New inbound rule - " formatPort(local[2], $1, name));
  INPUT_RULES[local[2] "/" $1] = 1;
}

$2 in OUTBOUND_CONNECTION_TYPES_ARRAY {
  if(remoteIP) {
    if(OUTPUT_RULES[$6 "/" $1]) next;
  } else {
    if(OUTPUT_RULES[remote[2] "/" $1]) next;
  }
  if(remote[2] in OUTBOUND_PORT_WHITELIST_ARRAY == 0) {
    printLog("WARNING", "Outbound connection " formatPort(remote[2], $1, name) " not in whitelist, skipping.");
    next;
  }
  if(remoteIP)
    remoteIPMatcher = "-d " remoteIP;
  else
    remoteIPMatcher = "";
  if(name)
    comment = "-m comment --comment \"" name "\"";
  else
    comment = "";
  print(IPTABLES_CMD " -A " DEFAULT_OUTPUT_CHAIN " -p " $1 " -m " $1 " --dport " remote[2] " " remoteIPMatcher " -j ACCEPT");
  printLog("INFO", "New outbound rule - " sprintf("%15s", remoteIP) ":" formatPort(remote[2], $1, name));
  if(remoteIP)
    OUTPUT_RULES[$6 "/" $1] = 1;
  else
    OUTPUT_RULES[remote[2] "/" $1] = 1;
}
EOF

    # Replace the placeholder with the chosen DNS value
    sed -i "s/##DNS_SERVERS##/$dns_value/" "$tmpfile"
    
    # Make the temporary script executable and run it with sudo
    chmod +x "$tmpfile"
    sudo "$tmpfile"
    rm "$tmpfile"
    
    # Ask whether to enter additional (extended) iptables management
    ext_choice=$(get_input_string "Would you like to add any additional iptables rules? (y/n): ")
    if [[ "$ext_choice" == "y" || "$ext_choice" == "Y" ]]; then
        extended_iptables
    fi
}


# FUNCTION: custom_iptables_manual_rules (inbound)
function custom_iptables_manual_rules {
    print_banner "Manual Inbound IPtables Rule Addition"
    echo "[*] Enter port numbers (one per line) for which you wish to allow inbound TCP traffic."
    echo "    Press ENTER on a blank line when finished."
    ports=$(get_input_list)
    for port in $ports; do
        sudo iptables -A INPUT --protocol tcp --dport "$port" -j ACCEPT
        echo "[*] Inbound iptables rule added for port $port (TCP)"
    done
}

# FUNCTION: custom_iptables_manual_outbound_rules
function custom_iptables_manual_outbound_rules {
    print_banner "Manual Outbound IPtables Rule Addition"
    echo "[*] Enter port numbers (one per line) for which you wish to allow outbound TCP traffic."
    echo "    Press ENTER on a blank line when finished."
    ports=$(get_input_list)
    for port in $ports; do
        sudo iptables -A OUTPUT --protocol tcp --dport "$port" -j ACCEPT
        echo "[*] Outbound iptables rule added for port $port (TCP)"
    done
}

# FUNCTION: extended_iptables
# Provides an interactive loop for extended IPtables management.
# Options include:
#   1) Add Outbound Rule (ACCEPT)
#   2) Add Inbound Rule (ACCEPT)
#   3) Deny Outbound Rule (DROP)
#   4) Deny Inbound Rule (DROP)
#   5) Show All Rules
#   6) Reset Firewall
#   7) Exit Extended IPtables Management
function extended_iptables {
    while true; do
        print_banner "Extended IPtables Management"
        echo "Select an option:"
        echo "  1) Add Outbound Rule (ACCEPT)"
        echo "  2) Add Inbound Rule (ACCEPT)"
        echo "  3) Deny Outbound Rule (DROP)"
        echo "  4) Deny Inbound Rule (DROP)"
        echo "  5) Show All Rules"
        echo "  6) Reset Firewall"
        echo "  7) Exit Extended IPtables Management"
        read -p "Enter your choice [1-7]: " choice
        case $choice in
            1)
                read -p "Enter outbound port number: " port
                sudo iptables -A OUTPUT --protocol tcp --dport "$port" -j ACCEPT
                echo "Outbound ACCEPT rule added for port $port"
                ;;
            2)
                read -p "Enter inbound port number: " port
                sudo iptables -A INPUT --protocol tcp --dport "$port" -j ACCEPT
                echo "Inbound ACCEPT rule added for port $port"
                ;;
            3)
                read -p "Enter outbound port number to deny: " port
                sudo iptables -A OUTPUT --protocol tcp --dport "$port" -j DROP
                echo "Outbound DROP rule added for port $port"
                ;;
            4)
                read -p "Enter inbound port number to deny: " port
                sudo iptables -A INPUT --protocol tcp --dport "$port" -j DROP
                echo "Inbound DROP rule added for port $port"
                ;;
            5)
                sudo iptables -L -n -v
                ;;
            6)
                reset_iptables
                ;;
            7)
                echo "Exiting Extended IPtables Management."
                break
                ;;
            *)
                echo "Invalid option selected."
                ;;
        esac
        echo ""
    done
}

# FUNCTION: reset_iptables
# This function resets the IPtables firewall by flushing all rules,
# deleting all user-defined chains, zeroing packet and byte counters,
# and setting the default policies for the INPUT, FORWARD, and OUTPUT chains to ACCEPT.
function reset_iptables {
    print_banner "Resetting IPtables Firewall"
    echo "[*] Flushing all iptables rules..."
    sudo iptables -F
    sudo iptables -X
    sudo iptables -Z
    echo "[*] Setting default policies to ACCEPT..."
    sudo iptables -P INPUT ACCEPT
    sudo iptables -P FORWARD ACCEPT
    sudo iptables -P OUTPUT ACCEPT
    echo "[*] IPtables firewall has been reset."
}

########################################################################

function backups {
    print_banner "Backups"
    echo "[*] Would you like to backup any files? (y/N): "
    option=$(get_input_string "(y/N): ")
    if [ "$option" != "y" ]; then
        return
    fi

    # Pre-check for critical web directories
    default_web_dirs=(
        "/etc/nginx" 
        "/etc/apache2" 
        "/usr/share/nginx" 
        "/var/www" 
        "/var/www/html" 
        "/etc/lighttpd" 
        "/etc/mysql" 
        "/etc/postgresql" 
        "/var/lib/apache2" 
        "/var/lib/mysql" 
        "/etc/redis" 
        "/etc/phpMyAdmin" 
        "/etc/php.d"
    )
    detected_web_dirs=()
    echo "[*] Scanning for critical web directories..."
    for dir in "${default_web_dirs[@]}"; do
        if [ -d "$dir" ]; then
            detected_web_dirs+=("$dir")
        fi
    done

    dirs_to_backup=()
    if [ ${#detected_web_dirs[@]} -gt 0 ]; then
        echo "[*] The following critical web directories have been detected:"
        for d in "${detected_web_dirs[@]}"; do
            echo "    $d"
        done
        read -p "Would you like to include these directories in the backup? (y/n): " web_choice
        if [[ "$web_choice" == "y" || "$web_choice" == "Y" ]]; then
            dirs_to_backup=("${detected_web_dirs[@]}")
        else
            echo "[*] Skipping auto-detected web directories."
        fi
    else
        echo "[*] No critical web directories were automatically detected."
    fi

    # Prompt for additional directories/files manually
    read -p "Would you like to add additional directories/files to backup? (y/n): " add_choice
    if [[ "$add_choice" == "y" || "$add_choice" == "Y" ]]; then
        echo "[*] Enter additional directories/files to backup (one per line; hit ENTER on a blank line to finish):"
        manual_dirs=$(get_input_list)
        for item in $manual_dirs; do
            path=$(readlink -f "$item")
            if sudo [ -e "$path" ]; then
                dirs_to_backup+=("$path")
            else
                echo "[X] ERROR: $path is invalid or does not exist."
            fi
        done
    fi

    # If still no directories, prompt the user once more for manual entry.
    if [ ${#dirs_to_backup[@]} -eq 0 ]; then
        read -p "No directories selected. Would you like to manually enter directories/files to backup? (y/n): " manual_prompt
        if [[ "$manual_prompt" == "y" || "$manual_prompt" == "Y" ]]; then
            echo "[*] Enter directories/files to backup (one per line; hit ENTER on a blank line to finish):"
            manual_dirs=$(get_input_list)
            for item in $manual_dirs; do
                path=$(readlink -f "$item")
                if sudo [ -e "$path" ]; then
                    dirs_to_backup+=("$path")
                else
                    echo "[X] ERROR: $path is invalid or does not exist."
                fi
            done
        fi
    fi

    # If no directories are selected, exit backup.
    if [ ${#dirs_to_backup[@]} -eq 0 ]; then
        echo "[*] No directories/files selected for backup. Exiting backup function."
        return
    fi

    # Get backup storage name
    while true; do
        backup_name=$(get_input_string "Enter name for encrypted backups file (ex. cosmo.zip): ")
        if [ "$backup_name" != "" ]; then
            break
        fi
        echo "[X] ERROR: Backup name cannot be blank."
    done

    # Get backup storage location
    while true; do
        backup_dir=$(get_input_string "Enter directory to place encrypted backups file (ex. /var/log/): ")
        backup_dir=$(readlink -f "$backup_dir")
        if sudo [ -e "$backup_dir" ]; then
            break
        fi
        echo "[X] ERROR: $backup_dir is invalid or does not exist."
    done

    echo "[*] Enter the backup encryption password."
    while true; do
        password=$(get_silent_input_string "Enter password: ")
        echo
        confirm_password=$(get_silent_input_string "Confirm password: ")
        echo
        if [ "$password" != "$confirm_password" ]; then
            echo "Passwords do not match. Please retry."
        else
            break
        fi
    done

    # Create backup directory for individual zip files
    sudo mkdir -p "$backup_dir/backups"
    for dir in "${dirs_to_backup[@]}"; do
        filename=$(basename "$dir")
        sudo zip -r "$backup_dir/backups/$filename.zip" "$dir" &> /dev/null
    done

    # Compress the backups directory into one archive
    tar -czvf "$backup_dir/backups.tar.gz" -C "$backup_dir" backups &>/dev/null

    # Encrypt the archive
    openssl enc -aes-256-cbc -salt -in "$backup_dir/backups.tar.gz" -out "$backup_dir/$backup_name" -k "$password"

    # Verify backup creation and cleanup intermediary files
    if sudo [ -e "$backup_dir/$backup_name" ]; then
        sudo rm "$backup_dir/backups.tar.gz"
        sudo rm -rf "$backup_dir/backups"
        echo "[*] Backups successfully stored and encrypted."
    else
        echo "[X] ERROR: Could not successfully create backups."
    fi
}

function setup_splunk {
    print_banner "Installing Splunk"
    indexer_ip=$(get_input_string "What is the Splunk forward server ip? ")

    wget $GITHUB_URL/splunk/splunk.sh --no-check-certificate
    chmod +x splunk.sh
    ./splunk.sh -f $indexer_ip
}


##################### ADDITIONAL WEB HARDENING FUNCTIONS #####################

function backup_databases {
    print_banner "Hardening Databases"
    # Check if MySQL/MariaDB is active and if default (empty) root login works.
    sudo service mysql status >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "[+] mysql/mariadb is active!"
        sudo mysql -u root -e "quit" 2>/dev/null
        if [ $? -eq 0 ]; then
            echo "[!] Able to login with empty password on the mysql database!"
            echo "[*] Backing up all databases..."
            sudo mysqldump --all-databases > backup.sql
            ns=$(date +%N)
            pass=$(echo "${ns}$REPLY" | sha256sum | cut -d" " -f1)
            echo "[+] Backed up database. Key for database dump: $pass"
            gpg -c --pinentry-mode=loopback --passphrase "$pass" backup.sql
            sudo rm backup.sql
        fi
    fi

    # Check if PostgreSQL is active
    sudo service postgresql status >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "[+] PostgreSQL is active!"
    fi
}

function secure_php_ini {
    print_banner "Securing php.ini Files"
    for ini in $(find / -name "php.ini" 2>/dev/null); do
        echo "[+] Writing php.ini options to $ini..."
        echo "disable_functions = shell_exec, exec, passthru, proc_open, popen, system, phpinfo" | sudo tee -a "$ini" >/dev/null
        echo "max_execution_time = 3" | sudo tee -a "$ini" >/dev/null
        echo "register_globals = off" | sudo tee -a "$ini" >/dev/null
        echo "magic_quotes_gpc = on" | sudo tee -a "$ini" >/dev/null
        echo "allow_url_fopen = off" | sudo tee -a "$ini" >/dev/null
        echo "allow_url_include = off" | sudo tee -a "$ini" >/dev/null
        echo "display_errors = off" | sudo tee -a "$ini" >/dev/null
        echo "short_open_tag = off" | sudo tee -a "$ini" >/dev/null
        echo "session.cookie_httponly = 1" | sudo tee -a "$ini" >/dev/null
        echo "session.use_only_cookies = 1" | sudo tee -a "$ini" >/dev/null
        echo "session.cookie_secure = 1" | sudo tee -a "$ini" >/dev/null
    done
}

function secure_ssh {
    print_banner "Securing SSH"
    if sudo service sshd status > /dev/null; then
        # Enable root login and disable public-key authentication for root
        sudo sed -i '1s;^;PermitRootLogin yes\n;' /etc/ssh/sshd_config
        sudo sed -i '1s;^;PubkeyAuthentication no\n;' /etc/ssh/sshd_config

        # For non-RedHat systems, disable PAM in sshd_config
        if ! grep -qi "REDHAT_" /etc/os-release; then
            sudo sed -i '1s;^;UsePAM no\n;' /etc/ssh/sshd_config
        fi

        sudo sed -i '1s;^;UseDNS no\n;' /etc/ssh/sshd_config
        sudo sed -i '1s;^;PermitEmptyPasswords no\n;' /etc/ssh/sshd_config
        sudo sed -i '1s;^;AddressFamily inet\n;' /etc/ssh/sshd_config
        sudo sed -i '1s;^;Banner none\n;' /etc/ssh/sshd_config

        # Restart the SSH service if the configuration tests out
        sudo sshd -t && sudo systemctl restart sshd
    fi
}

function install_modsecurity {
    print_banner "Installing ModSecurity"
    local ipt
    ipt=$(command -v iptables || command -v /sbin/iptables || command -v /usr/sbin/iptables)
    sudo $ipt -P OUTPUT ACCEPT

    if command -v yum >/dev/null; then
        # RHEL-based systems (not implemented in this snippet)
        echo "RHEL-based ModSecurity installation not implemented"
    elif command -v apt-get >/dev/null; then
        # Debian/Ubuntu (and other Debian-based) systems
        sudo apt-get update
        sudo apt-get -y install libapache2-mod-security2
        sudo a2enmod security2
        sudo cp /etc/modsecurity/modsecurity.conf-recommended /etc/modsecurity/modsecurity.conf
        sudo sed -i 's/SecRuleEngine DetectionOnly/SecRuleEngine On/g' /etc/modsecurity/modsecurity.conf
        sudo systemctl restart apache2
    elif command -v apk >/dev/null; then
        # Alpine-based systems (not implemented in this snippet)
        echo "Alpine-based ModSecurity installation not implemented"
    else
        echo "Unsupported distribution for ModSecurity installation"
        exit 1
    fi

    sudo $ipt -P OUTPUT DROP
}

function remove_profiles {
    print_banner "Removing Profile Files"
    sudo mv /etc/prof{i,y}le.d 2>/dev/null
    sudo mv /etc/prof{i,y}le 2>/dev/null
    for f in ".profile" ".bashrc" ".bash_login"; do
        find /home /root -name "$f" -exec sudo rm {} \;
    done
}

function fix_pam {
    print_banner "Fixing PAM Configuration"
    local ipt
    ipt=$(command -v iptables || command -v /sbin/iptables || command -v /usr/sbin/iptables)
    sudo $ipt -P OUTPUT ACCEPT

    if command -v yum >/dev/null; then
        if command -v authconfig >/dev/null; then
            sudo authconfig --updateall
            sudo yum -y reinstall pam
        else
            echo "No authconfig, cannot fix PAM on this system"
        fi
    elif command -v apt-get >/dev/null; then
        sudo DEBIAN_FRONTEND=noninteractive pam-auth-update --force
        sudo apt-get -y --reinstall install libpam-runtime libpam-modules
    elif command -v apk >/dev/null; then
        if [ -d /etc/pam.d ]; then
            sudo apk fix --purge linux-pam
            for file in $(find /etc/pam.d -name "*.apk-new" 2>/dev/null); do
                sudo mv "$file" "$(echo $file | sed 's/.apk-new//g')"
            done
        else
            echo "PAM is not installed"
        fi
    elif command -v pacman >/dev/null; then
        if [ -z "$BACKUPDIR" ]; then
            echo "No backup directory provided for PAM configs"
        else
            sudo mv /etc/pam.d /etc/pam.d.backup
            sudo cp -R "$BACKUPDIR" /etc/pam.d
        fi
        sudo pacman -S pam --noconfirm
    else
        echo "Unknown OS, not fixing PAM"
    fi

    sudo $ipt -P OUTPUT DROP
}

function search_ssn {
    print_banner "Searching for SSN Patterns"
    local rootdir="/home/"
    local ssn_pattern='[0-9]\{3\}-[0-9]\{2\}-[0-9]\{4\}'
    sudo find "$rootdir" -type f \( -name "*.txt" -o -name "*.csv" \) -exec sh -c '
        file="$1"
        pattern="$2"
        grep -Hn "$pattern" "$file" | while read -r line; do
            echo "$file:SSN:$line"
        done
    ' sh '{}' "$ssn_pattern" \;
}

function remove_unused_packages {
    print_banner "Removing Unused Packages"
    if command -v yum >/dev/null; then
        sudo yum purge -y -q netcat nc gcc cmake make telnet
    elif command -v apt-get >/dev/null; then
        sudo apt-get -y purge netcat nc gcc cmake make telnet
    elif command -v apk >/dev/null; then
        sudo apk remove gcc make
    else
        echo "Unsupported package manager for package removal"
    fi
}

function patch_vulnerabilities {
    print_banner "Patching Vulnerabilities"
    # Patch pwnkit vulnerability
    sudo chmod 0755 /usr/bin/pkexec

    # Patch CVE-2023-32233 vulnerability
    sudo sysctl -w kernel.unprivileged_userns_clone=0
    echo "kernel.unprivileged_userns_clone = 0" | sudo tee -a /etc/sysctl.conf >/dev/null
    sudo sysctl -p >/dev/null
}

function check_permissions {
    print_banner "Checking and Setting Permissions"
    sudo chown root:root /etc/shadow
    sudo chown root:root /etc/passwd
    sudo chmod 640 /etc/shadow
    sudo chmod 644 /etc/passwd

    echo "[+] SUID binaries:"
    sudo find / -perm -4000 2>/dev/null

    echo "[+] Directories with 777 permissions (max depth 3):"
    sudo find / -maxdepth 3 -type d -perm -777 2>/dev/null

    echo "[+] Files with capabilities:"
    sudo getcap -r / 2>/dev/null

    echo "[+] Files with extended ACLs in critical directories:"
    sudo getfacl -sR /etc/ /usr/ /root/
}

function sysctl_config {
    print_banner "Applying sysctl Configurations"
    local file="/etc/sysctl.conf"
    echo "net.ipv4.tcp_syncookies = 1" | sudo tee -a "$file" >/dev/null
    echo "net.ipv4.tcp_synack_retries = 2" | sudo tee -a "$file" >/dev/null
    echo "net.ipv4.tcp_challenge_ack_limit = 1000000" | sudo tee -a "$file" >/dev/null
    echo "net.ipv4.tcp_rfc1337 = 1" | sudo tee -a "$file" >/dev/null
    echo "net.ipv4.icmp_ignore_bogus_error_responses = 1" | sudo tee -a "$file" >/dev/null
    echo "net.ipv4.conf.all.accept_redirects = 0" | sudo tee -a "$file" >/dev/null
    echo "net.ipv4.icmp_echo_ignore_all = 1" | sudo tee -a "$file" >/dev/null
    echo "kernel.core_uses_pid = 1" | sudo tee -a "$file" >/dev/null
    echo "kernel.kptr_restrict = 2" | sudo tee -a "$file" >/dev/null
    echo "kernel.perf_event_paranoid = 2" | sudo tee -a "$file" >/dev/null
    echo "kernel.randomize_va_space = 2" | sudo tee -a "$file" >/dev/null
    echo "kernel.sysrq = 0" | sudo tee -a "$file" >/dev/null
    echo "kernel.yama.ptrace_scope = 2" | sudo tee -a "$file" >/dev/null
    echo "fs.protected_hardlinks = 1" | sudo tee -a "$file" >/dev/null
    echo "fs.protected_symlinks = 1" | sudo tee -a "$file" >/dev/null
    echo "fs.suid_dumpable = 0" | sudo tee -a "$file" >/dev/null
    echo "kernel.unprivileged_userns_clone = 0" | sudo tee -a "$file" >/dev/null
    echo "fs.protected_fifos = 2" | sudo tee -a "$file" >/dev/null
    echo "fs.protected_regular = 2" | sudo tee -a "$file" >/dev/null
    echo "kernel.kptr_restrict = 2" | sudo tee -a "$file" >/dev/null

    sudo sysctl -p >/dev/null
}

# my_secure_sql_installation
function my_secure_sql_installation {
    print_banner "My Secure SQL Installation"
    read -p "Would you like to run mysql_secure_installation? (y/n): " sql_choice
    if [[ "$sql_choice" == "y" || "$sql_choice" == "Y" ]]; then
         echo "[*] Running mysql_secure_installation..."
         sudo mysql_secure_installation
    else
         echo "[*] Skipping mysql_secure_installation."
    fi
}

# FUNCTION: manage_web_immutability
# This function scans for default critical web directories (e.g., /etc/nginx, /etc/apache2, /var/www, etc.),
# lists any that are found, and then prompts the user to either set the immutable flag (chattr +i) on these directories,
# or to remove the immutable flag (chattr -i). This applies only to production web directories.
function manage_web_immutability {
    print_banner "Manage Web Directory Immutability"
    
    # List of common critical web directories (you may add or remove as needed)
    default_web_dirs=(
        "/etc/nginx"
        "/etc/apache2"
        "/usr/share/nginx"
        "/var/www"
        "/var/www/html"
        "/etc/lighttpd"
        "/etc/mysql"
        "/etc/postgresql"
        "/var/lib/apache2"
        "/var/lib/mysql"
        "/etc/redis"
        "/etc/phpMyAdmin"
        "/etc/php.d"
    )
    
    detected_web_dirs=()
    echo "[*] Scanning for critical web directories..."
    for dir in "${default_web_dirs[@]}"; do
        if [ -d "$dir" ]; then
            detected_web_dirs+=("$dir")
        fi
    done

    if [ ${#detected_web_dirs[@]} -eq 0 ]; then
        echo "[*] No critical web directories were found."
        return
    fi

    echo "[*] The following web directories have been detected:"
    for d in "${detected_web_dirs[@]}"; do
        echo "    $d"
    done

    read -p "Would you like to set these directories to immutable? (y/n): " imm_choice
    if [[ "$imm_choice" == "y" || "$imm_choice" == "Y" ]]; then
        for d in "${detected_web_dirs[@]}"; do
            sudo chattr +i "$d"
            echo "[*] Set immutable flag on $d"
        done
    else
        read -p "Would you like to remove the immutable flag from these directories? (y/n): " unimm_choice
        if [[ "$unimm_choice" == "y" || "$unimm_choice" == "Y" ]]; then
            for d in "${detected_web_dirs[@]}"; do
                sudo chattr -i "$d"
                echo "[*] Removed immutable flag from $d"
            done
        else
            echo "[*] No changes made to web directory immutability."
        fi
    fi
}

# harden_web function:
function harden_web {
    print_banner "Web Hardening Initiated"
    backup_databases
    secure_php_ini
    install_modsecurity
    my_secure_sql_installation
    manage_web_immutability
}

##################### NEW WEB HARDENING MENU FUNCTION #####################
function show_web_hardening_menu {
    print_banner "Web Hardening Menu"
    echo "1) Run Full Web Hardening Process"
    echo "2) backup_databases"
    echo "3) secure_php_ini"
    echo "4) install_modsecurity"
    echo "5) my_secure_sql_installation"
    echo "6) manage_web_immutability"
    echo "7) Exit Web Hardening Menu"
    read -p "Enter your choice [1-7]: " web_menu_choice
    case $web_menu_choice in
        1)
            print_banner "Web Hardening Initiated"
            backup_databases
            secure_php_ini
            install_modsecurity
            my_secure_sql_installation
            manage_web_immutability
            ;;
        2)
            print_banner "Web Hardening Initiated"
            backup_databases
            ;;
        3)
            print_banner "Web Hardening Initiated"
            secure_php_ini
            ;;
        4)
            print_banner "Web Hardening Initiated"
            install_modsecurity
            ;;
        5)
            print_banner "Web Hardening Initiated"
            my_secure_sql_installation
            ;;
        6)
            print_banner "Web Hardening Initiated"
            manage_web_immutability
            ;;
        7)
            echo "[*] Exiting Web Hardening Menu"
            ;;
        *)
            echo "[X] Invalid option."
            ;;
    esac
}

##################### MENU FUNCTION #####################
function show_menu {
    print_banner "Hardening Script Menu"
    echo "1) Full Hardening Process (Run all)"
    echo "2) User Management"
    echo "3) Firewall Configuration"
    echo "4) Backups"
    echo "5) Splunk Installation"
    echo "6) SSH Hardening"
    echo "7) PAM/Profile Fixes & System Config"
    echo "8) Web Hardening"
    echo "9) Exit"
    echo
    read -p "Enter your choice [1-9]: " menu_choice
    echo
    case $menu_choice in
        1) main ;;
        2)
            detect_system_info
            install_prereqs
            create_ccdc_users
            change_passwords
            disable_users
            remove_sudoers ;;
        3)
            detect_system_info
            install_prereqs
            disable_other_firewalls
            echo "[*] Choose a firewall configuration option:"
            echo "    1) Setup UFW"
            echo "    2) Setup full IPtables (Custom Script)"
            echo "    3) Create additional INBOUND Allow IPtables rules"
            echo "    4) Create additional OUTBOUND Allow IPtables rules"
            echo "    5) Create additional INBOUND Deny IPtables rules"
            echo "    6) Create additional OUTBOUND Deny IPtables rules"
            echo "    7) Reset IPtables firewall"
            echo "    8) Show all IPtables rules"
            read -p "Enter your choice [1-8]: " fw_option
            case $fw_option in
                1) setup_ufw ;;
                2) setup_custom_iptables ;;
                3) custom_iptables_manual_rules ;;
                4) custom_iptables_manual_outbound_rules ;;
                5)
                    read -p "Enter inbound port number to DENY: " port
                    sudo iptables -A INPUT --protocol tcp --dport "$port" -j DROP
                    echo "Inbound DROP rule added for port $port"
                    ;;
                6)
                    read -p "Enter outbound port number to DENY: " port
                    sudo iptables -A OUTPUT --protocol tcp --dport "$port" -j DROP
                    echo "Outbound DROP rule added for port $port"
                    ;;
                7) reset_iptables ;;
                8) sudo iptables -L -n -v ;;
                *) echo "[X] Invalid choice. Exiting." ; exit 1 ;;
            esac ;;
        4) backups ;;
        5) setup_splunk ;;
        6) secure_ssh ;;
        7)
            fix_pam
            remove_profiles
            check_permissions
            sysctl_config ;;
        8) show_web_hardening_menu ;;
        9) echo "Exiting..."; exit 0 ;;
        *) echo "Invalid option. Exiting." ; exit 1 ;;
    esac
}

##################### MAIN FUNCTION #####################
function main {
    echo "CURRENT TIME: $(date +"%Y-%m-%d_%H:%M:%S")"
    echo "[*] Start of full hardening process"
    detect_system_info
    install_prereqs
    create_ccdc_users
    change_passwords
    disable_users
    remove_sudoers
    disable_other_firewalls
    echo "[*] Choose a firewall configuration option:"
    echo "    1) Setup UFW"
    echo "    2) Setup full IPtables (Custom Script)"
    echo "    3) Show all IPtables rules"
    echo "    4) Create additional INBOUND Allow IPtables rules"
    echo "    5) Create additional OUTBOUND Allow IPtables rules"
    echo "    6) Create additional INBOUND Deny IPtables rules"
    echo "    7) Create additional OUTBOUND Deny IPtables rules"
    echo "    8) Reset IPtables firewall (flush all rules, delete chains, reset counters)"
    read -p "Enter your choice [1-8]: " fw_choice
    case $fw_choice in
        1)
            setup_ufw
            ;;
        2)
            setup_custom_iptables
            ;;
        3)
            sudo iptables -L -n -v
            ;;
        4)
            custom_iptables_manual_rules
            ;;
        5)
            custom_iptables_manual_outbound_rules
            ;;
        6)
            read -p "Enter inbound port number to DENY: " port
            sudo iptables -A INPUT --protocol tcp --dport "$port" -j DROP
            echo "Inbound DROP rule added for port $port"
            ;;
        7)
            read -p "Enter outbound port number to DENY: " port
            sudo iptables -A OUTPUT --protocol tcp --dport "$port" -j DROP
            echo "Outbound DROP rule added for port $port"
            ;;
        8)
            reset_iptables
            ;;
        *)
            echo "[X] Invalid choice. Defaulting to Setup UFW."
            setup_ufw
            ;;
    esac
    backups
    setup_splunk
    secure_ssh
    remove_profiles
    fix_pam
    search_ssn
    remove_unused_packages
    patch_vulnerabilities
    check_permissions
    sysctl_config
    web_choice=$(get_input_string "Would you like to perform web hardening? (y/N): ")
    if [ "$web_choice" == "y" ]; then
        show_web_hardening_menu
    fi
    echo "[*] End of full hardening process"
    echo "[*] Script log can be viewed at $LOG"
    echo "[*] ***Please install system updates now***"
}

##################### ARGUMENT PARSING #####################
for arg in "$@"; do
    case "$arg" in
        --debug )
            echo "[*] Debug mode enabled"
            debug="true"
            ;;
    esac
done

##################### LOGGING SETUP #####################
LOG_PATH=$(dirname "$LOG")
if [ ! -d "$LOG_PATH" ]; then
    sudo mkdir -p "$LOG_PATH"
    sudo chown root:root "$LOG_PATH"
    sudo chmod 750 "$LOG_PATH"
fi

##################### MAIN EXECUTION #####################
show_menu
