# ebt.zsh - ebtables reporting functions for AiMesh routers
# Source this file from .zshrc
#
# For Merlin community: Edit the USER CONFIGURATION section below for your network
#
# ═══════════════════════════════════════════════════════════════════════════════
# COMPATIBILITY
# ═══════════════════════════════════════════════════════════════════════════════
#
# Shell:     zsh (required - uses zsh-specific features)
# Firmware:  Asuswrt-Merlin (tested on 3004.388.x and 3006.102.x)
#
# Platforms:
#   macOS        - Works out of the box (zsh is default shell)
#   Linux        - Works if zsh installed (apt install zsh / yum install zsh)
#   Windows+WSL  - Works if zsh installed in WSL (apt install zsh)
#   Windows+Git Bash - NOT compatible (bash, not zsh)
#   PowerShell   - NOT compatible
#
# Requirements:
#   - SSH access to your router(s) with key-based or password authentication
#   - Router(s) running Asuswrt-Merlin firmware with ebtables support
#

# ═══════════════════════════════════════════════════════════════════════════════
# USER CONFIGURATION - Edit these for your network
# ═══════════════════════════════════════════════════════════════════════════════

# Router definitions: IP -> "Model (Shortname)"
# The shortname in parentheses is used for display and MAC labeling
# Mark one router as "(Primary)" - this is where DHCP/dnsmasq data is fetched from
typeset -gA _EBT_ROUTERS
_EBT_ROUTERS=(
    "10.10.3.1" "RT-BE92U (Primary)"
    "10.10.3.2" "AX86U (Mesh1)"
    "10.10.3.3" "AX88U-Pro (Mesh2)"
)

# Get SSH username for a router from environment variable
# Looks for EBT_SSH_USER_<SHORTNAME> (uppercase), falls back to EBT_SSH_USER
_ebt_get_ssh_user() {
    local ip="$1"
    local desc="${_EBT_ROUTERS[$ip]}"
    local shortname=""

    # Extract shortname from parentheses (same logic as _ebt_get_shortname)
    if [[ "$desc" =~ '\(([^)]+)\)' ]]; then
        shortname="${match[1]}"
    else
        shortname="$desc"
    fi

    local varname="EBT_SSH_USER_${shortname:u}"  # :u = uppercase
    local user="${(P)varname}"  # indirect variable expansion

    if [[ -z "$user" ]]; then
        user="${EBT_SSH_USER:-admin}"  # fallback to EBT_SSH_USER or "admin"
    fi
    echo "$user"
}

# SSH command to reach each router
# Must accept a command string as the final argument
#
# SSH username is read from environment variables:
#   EBT_SSH_USER_<SHORTNAME>  - per-router (e.g., EBT_SSH_USER_PRIMARY, EBT_SSH_USER_MESH1)
#   EBT_SSH_USER              - fallback for all routers (default: "admin")
# Shortnames are derived from _EBT_ROUTERS above (uppercase)
#
# Examples for _EBT_ROUTER_SSH entries:
#   "ssh $(_ebt_get_ssh_user 192.168.1.1)@192.168.1.1"           # default port 22
#   "ssh -p 2222 $(_ebt_get_ssh_user 192.168.1.1)@192.168.1.1"   # custom port
#   "ssh -i ~/.ssh/router_key $(_ebt_get_ssh_user 192.168.1.1)@192.168.1.1"  # specific key
typeset -gA _EBT_ROUTER_SSH
_EBT_ROUTER_SSH=(
    "10.10.3.1" "ssh -p 202 $(_ebt_get_ssh_user 10.10.3.1)@10.10.3.1"
    "10.10.3.2" "ssh -p 202 $(_ebt_get_ssh_user 10.10.3.2)@10.10.3.2"
    "10.10.3.3" "ssh -p 202 $(_ebt_get_ssh_user 10.10.3.3)@10.10.3.3"
)

# MAC mapping file location (where hostname lookups are cached)
_EBT_MACMAP_FILE="$HOME/.ebt_macmap.tmp"

# ═══════════════════════════════════════════════════════════════════════════════
# END USER CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════════

# Colors for output
typeset -gA _EBT_COLORS
_EBT_COLORS=(
    reset    $'\e[0m'
    bold     $'\e[1m'
    dim      $'\e[2m'
    red      $'\e[31m'
    green    $'\e[32m'
    yellow   $'\e[33m'
    blue     $'\e[34m'
    magenta  $'\e[35m'
    cyan     $'\e[36m'
)

# ═══════════════════════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

# Execute command on router via SSH
# Usage: _ebt_ssh <ip> <command>
_ebt_ssh() {
    local ip="$1"
    local cmd="$2"
    local ssh_cmd="${_EBT_ROUTER_SSH[$ip]}"

    if [[ -z "$ssh_cmd" ]]; then
        echo "Error: No SSH configuration for $ip" >&2
        return 1
    fi

    eval "$ssh_cmd -o ConnectTimeout=5 -o BatchMode=yes '$cmd'" 2>/dev/null
}

# Extract shortname from router description
# "RT-BE92U (Primary)" -> "Primary"
# "AX86U (Mesh1)" -> "Mesh1"
_ebt_get_shortname() {
    local ip="$1"
    local desc="${_EBT_ROUTERS[$ip]}"

    if [[ "$desc" =~ '\(([^)]+)\)' ]]; then
        echo "${match[1]}"
    else
        # No parentheses - use the whole description
        echo "$desc"
    fi
}

# Get the primary router IP (the one with "Primary" in description)
_ebt_get_primary() {
    for ip in ${(k)_EBT_ROUTERS}; do
        if [[ "${_EBT_ROUTERS[$ip]}" == *"Primary"* ]]; then
            echo "$ip"
            return 0
        fi
    done
    # Fallback to first router
    echo "${${(k)_EBT_ROUTERS}[1]}"
}

# Build list of valid router names for help text (shows both name and IP)
_ebt_router_names_help() {
    local entries=""
    for ip in ${(ko)_EBT_ROUTERS}; do
        local shortname=$(_ebt_get_shortname "$ip")
        entries+="${shortname:l}/${ip}, "  # :l for lowercase
    done
    echo "${entries%, }"  # Remove trailing ", "
}

# Normalize MAC address (lowercase, with leading zeros)
_ebt_normalize_mac() {
    local mac="$1"
    echo "$mac" | tr '[:upper:]' '[:lower:]' | awk -F: '{
        for(i=1;i<=NF;i++) {
            if(length($i)==1) $i="0"$i
        }
        print $1":"$2":"$3":"$4":"$5":"$6
    }'
}

# Build hostname lookup from macmap.tmp file
# If file doesn't exist or --refresh is passed, calls map_macs() first
_ebt_build_hostname_cache() {
    local refresh="${1:-}"
    typeset -gA _EBT_MAC_TO_HOST
    _EBT_MAC_TO_HOST=()

    local macmap="$_EBT_MACMAP_FILE"

    # Check if we need to build/refresh the mapping file
    if [[ "$refresh" == "--refresh" || ! -f "$macmap" ]]; then
        map_macs
    fi

    # Load from macmap.tmp
    if [[ -f "$macmap" ]]; then
        while IFS=$'\t' read -r mac hostname; do
            [[ -z "$mac" ]] && continue
            _EBT_MAC_TO_HOST[$mac]="$hostname"
        done < "$macmap"
    fi
}

# Mask a MAC address (replace last two octets with xx:xx)
_ebt_mask_mac() {
    local mac="$1"
    echo "$mac" | sed 's/:[^:]*:[^:]*$/:xx:xx/'
}

# Resolve MAC to hostname string
_ebt_resolve_mac() {
    local mac="$1"
    local use_color="${2:-true}"
    local mask_mac="${3:-false}"
    local norm_mac=$(_ebt_normalize_mac "$mac")
    local hostname="${_EBT_MAC_TO_HOST[$norm_mac]}"
    local display_mac="$mac"

    # Mask MAC if requested
    if [[ "$mask_mac" == "true" ]]; then
        display_mac=$(_ebt_mask_mac "$mac")
    fi

    if [[ "$use_color" == "true" ]]; then
        if [[ -n "$hostname" ]]; then
            echo "${_EBT_COLORS[cyan]}$display_mac${_EBT_COLORS[reset]} ${_EBT_COLORS[dim]}($hostname)${_EBT_COLORS[reset]}"
        else
            echo "${_EBT_COLORS[cyan]}$display_mac${_EBT_COLORS[reset]}"
        fi
    else
        if [[ -n "$hostname" ]]; then
            echo "$display_mac ($hostname)"
        else
            echo "$display_mac"
        fi
    fi
}

# Get source column text (plain, for width calculation)
# Returns: "-s MAC (hostname)" or "-d MAC (hostname)" for dest-only rules, or empty
_ebt_get_src_text() {
    local rule="$1"
    local mask_mac="${2:-false}"
    local src_mac=""
    local dst_mac=""

    # Extract source MAC
    if [[ "$rule" =~ '-s ([0-9a-fA-F]+:[0-9a-fA-F:]+)' ]]; then
        src_mac="${match[1]}"
    fi

    # Extract destination MAC (for rules with no source)
    if [[ "$rule" =~ '-d ([0-9a-fA-F]+:[0-9a-fA-F:]+)' ]]; then
        dst_mac="${match[1]}"
    fi

    if [[ -n "$src_mac" ]]; then
        local norm_mac=$(_ebt_normalize_mac "$src_mac")
        local hostname="${_EBT_MAC_TO_HOST[$norm_mac]}"
        local display_mac="$src_mac"
        [[ "$mask_mac" == "true" ]] && display_mac=$(_ebt_mask_mac "$src_mac")
        if [[ -n "$hostname" ]]; then
            echo "-s $display_mac ($hostname)"
        else
            echo "-s $display_mac"
        fi
    elif [[ -n "$dst_mac" ]]; then
        # Dest-only rule (no source)
        local norm_mac=$(_ebt_normalize_mac "$dst_mac")
        local hostname="${_EBT_MAC_TO_HOST[$norm_mac]}"
        local display_mac="$dst_mac"
        [[ "$mask_mac" == "true" ]] && display_mac=$(_ebt_mask_mac "$dst_mac")
        if [[ -n "$hostname" ]]; then
            echo "-d $display_mac ($hostname)"
        else
            echo "-d $display_mac"
        fi
    fi
}

# Get description for a rule
_ebt_describe_rule() {
    local rule="$1"

    if [[ "$rule" == *"-j DROP"* ]]; then
        if [[ "$rule" == *"-s "* && "$rule" == *"-d "* ]]; then
            echo "Block src→dst traffic"
        elif [[ "$rule" == *"-s "* ]]; then
            echo "Block from this source"
        elif [[ "$rule" == *"-d "* ]]; then
            echo "Block to this dest"
        else
            echo "Drop packet"
        fi
    elif [[ "$rule" == *"Broadcast"*"-j ACCEPT"* ]]; then
        echo "Allow broadcast from src"
    elif [[ "$rule" == *"-j ACCEPT"* ]]; then
        echo "Allow src→dst traffic"
    elif [[ "$rule" == *"mark --mark-or 0x5"* ]]; then
        echo "AiMesh traffic mark"
    elif [[ "$rule" == *"mark --mark-or 0x7"* ]]; then
        echo "AiMesh traffic mark"
    elif [[ "$rule" == *"mark"* ]]; then
        echo "Packet marking"
    else
        echo ""
    fi
}

# Extract packet count from rule line (from --Lc output)
# Returns the packet count or 0 if not found
_ebt_get_pcnt() {
    local rule="$1"
    if [[ "$rule" =~ 'pcnt = ([0-9]+)' ]]; then
        echo "${match[1]}"
    else
        echo "0"
    fi
}

# Format a rule with resolved hostnames and colors
# Args: rule, use_color, src_pad_width, mask_mac (optional)
_ebt_format_rule() {
    local rule="$1"
    local use_color="${2:-true}"
    local src_pad_width="${3:-0}"
    local mask_mac="${4:-false}"
    local formatted=""

    # Extract source MAC (must contain colons and be a valid MAC pattern)
    local src_mac=""
    if [[ "$rule" =~ '-s ([0-9a-fA-F]+:[0-9a-fA-F:]+)' ]]; then
        src_mac="${match[1]}"
    fi

    # Extract destination MAC (must contain colons and be a valid MAC pattern)
    local dst_mac=""
    if [[ "$rule" =~ '-d ([0-9a-fA-F]+:[0-9a-fA-F:]+)' ]]; then
        dst_mac="${match[1]}"
    fi

    # Build formatted rule
    formatted="$rule"

    # Replace source MAC (skip if Broadcast or not a valid MAC)
    if [[ -n "$src_mac" && "$src_mac" =~ ^[0-9a-fA-F]+: ]]; then
        local resolved=$(_ebt_resolve_mac "$src_mac" "$use_color" "$mask_mac")

        # Calculate padding if src_pad_width specified
        if [[ $src_pad_width -gt 0 ]]; then
            local plain_text=$(_ebt_get_src_text "$rule" "$mask_mac")
            local current_len=${#plain_text}
            local padding=""
            if [[ $current_len -lt $src_pad_width ]]; then
                padding=$(printf '%*s' $((src_pad_width - current_len)) '')
            fi
            formatted="${formatted//-s $src_mac/-s ${resolved}${padding}}"
        else
            formatted="${formatted//-s $src_mac/-s $resolved}"
        fi
    elif [[ -n "$dst_mac" && -z "$src_mac" && $src_pad_width -gt 0 ]]; then
        # Dest-only rule - pad the first (dest) column
        local resolved=$(_ebt_resolve_mac "$dst_mac" "$use_color" "$mask_mac")
        local plain_text=$(_ebt_get_src_text "$rule" "$mask_mac")
        local current_len=${#plain_text}
        local padding=""
        if [[ $current_len -lt $src_pad_width ]]; then
            padding=$(printf '%*s' $((src_pad_width - current_len)) '')
        fi
        formatted="${formatted//-d $dst_mac/-d ${resolved}${padding}}"
        dst_mac=""  # Clear so we don't replace again below
    fi

    # Replace destination MAC (skip if Broadcast or not a valid MAC)
    if [[ -n "$dst_mac" && "$dst_mac" =~ ^[0-9a-fA-F]+: ]]; then
        local resolved=$(_ebt_resolve_mac "$dst_mac" "$use_color" "$mask_mac")
        formatted="${formatted//-d $dst_mac/-d $resolved}"
    fi

    # Color the action
    if [[ "$use_color" == "true" ]]; then
        formatted="${formatted//-j DROP/${_EBT_COLORS[red]}-j DROP${_EBT_COLORS[reset]}}"
        formatted="${formatted//-j ACCEPT/${_EBT_COLORS[green]}-j ACCEPT${_EBT_COLORS[reset]}}"
        # Color the counters (from --Lc output) in magenta
        if [[ "$formatted" =~ ', pcnt = [0-9]+ -- bcnt = [0-9]+' ]]; then
            formatted="${formatted//, pcnt =/${_EBT_COLORS[magenta]}, pcnt =}"
            formatted="${formatted//-- bcnt = /-- bcnt = }"
            # Find where the bcnt value ends and add reset
            formatted=$(echo "$formatted" | sed -E "s/(bcnt = [0-9]+)/\1${_EBT_COLORS[reset]}/")
        fi
    fi

    # Add description
    local desc=$(_ebt_describe_rule "$rule")
    if [[ -n "$desc" ]]; then
        if [[ "$use_color" == "true" ]]; then
            formatted="$formatted  ${_EBT_COLORS[dim]}# $desc${_EBT_COLORS[reset]}"
        else
            formatted="$formatted  # $desc"
        fi
    fi

    echo "$formatted"
}

# Normalize rule for comparison
# Strips counters (from --Lc) before normalizing so rules match regardless of counter values
_ebt_normalize_rule() {
    echo "$1" | sed 's/, pcnt = [0-9]* -- bcnt = [0-9]*//' | tr -s ' ' | sed 's/^ *//' | awk '{
        for(i=1;i<=NF;i++) {
            if($i ~ /^[0-9a-fA-F:]+$/ && length($i) >= 11 && index($i,":") > 0) {
                n = split($i, parts, ":")
                if(n == 6) {
                    result = ""
                    for(j=1;j<=6;j++) {
                        if(length(parts[j])==1) parts[j]="0"parts[j]
                        result = result (j>1?":":"") tolower(parts[j])
                    }
                    $i = result
                }
            }
        }
        print
    }'
}

# Print formatted header
_ebt_header() {
    local title="$1"
    local use_color="${2:-true}"
    local line="════════════════════════════════════════════════════════════════════════════════"

    echo ""
    if [[ "$use_color" == "true" ]]; then
        echo "${_EBT_COLORS[bold]}${_EBT_COLORS[blue]}$line${_EBT_COLORS[reset]}"
        echo "${_EBT_COLORS[bold]}${_EBT_COLORS[blue]}  $title${_EBT_COLORS[reset]}"
        echo "${_EBT_COLORS[bold]}${_EBT_COLORS[blue]}$line${_EBT_COLORS[reset]}"
    else
        echo "$line"
        echo "  $title"
        echo "$line"
    fi
}

# Print sub-header
_ebt_subheader() {
    local title="$1"
    local use_color="${2:-true}"

    echo ""
    if [[ "$use_color" == "true" ]]; then
        echo "${_EBT_COLORS[yellow]}── $title ──${_EBT_COLORS[reset]}"
    else
        echo "── $title ──"
    fi
}

# Map router short names to IPs (dynamic based on _EBT_ROUTERS)
_ebt_resolve_router() {
    local name="$1"
    local name_lower="${name:l}"  # lowercase

    # Check if it's already an IP in our list
    if [[ -n "${_EBT_ROUTERS[$name]}" ]]; then
        echo "$name"
        return 0
    fi

    # Search by shortname or model name
    for ip in ${(k)_EBT_ROUTERS}; do
        local desc="${_EBT_ROUTERS[$ip]}"
        local shortname=$(_ebt_get_shortname "$ip")

        # Match shortname (e.g., "primary", "mesh1")
        if [[ "${shortname:l}" == "$name_lower" ]]; then
            echo "$ip"
            return 0
        fi

        # Match model name (e.g., "ax86u", "rt-be92u")
        local model="${desc%% \(*}"  # Get part before " ("
        if [[ "${model:l}" == "$name_lower" ]]; then
            echo "$ip"
            return 0
        fi
    done

    # Not found
    echo ""
}

# Main ebtables report function
ebt-report() {
    local use_color=true
    local filter_chain=""
    local refresh_macs=""
    local unique_only=false
    local mask_mac=false
    local show_count=false
    local min_count=0
    local -a selected_routers=()

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-color|-n) use_color=false; shift ;;
            --chain|-c) filter_chain="$2"; shift 2 ;;
            --refresh|-r) refresh_macs="--refresh"; shift ;;
            --unique|-u) unique_only=true; shift ;;
            --maskmac|-m) mask_mac=true; shift ;;
            --count)
                show_count=true
                # Check if next arg is a positive integer (optional min count)
                if [[ -n "$2" && "$2" =~ ^[0-9]+$ ]]; then
                    min_count="$2"
                    shift
                fi
                shift
                ;;
            --router|-R)
                local resolved=$(_ebt_resolve_router "$2")
                if [[ -z "$resolved" ]]; then
                    echo "Unknown router: $2"
                    echo "Valid: $(_ebt_router_names_help)"
                    return 1
                fi
                selected_routers+=("$resolved")
                shift 2
                ;;
            --help|-h)
                cat <<'HELPHEADER'
ebt-report - Display and compare ebtables rules across AiMesh routers

USAGE
    ebt-report [options]

DESCRIPTION
    Fetches ebtables rules from configured routers and displays them with
    MAC address resolution to hostnames. When viewing multiple routers,
    common rules are marked with ● and can be filtered with --unique.

OPTIONS
HELPHEADER
                echo "    --router, -R ROUTER  Include specific router (can be repeated)"
                echo "                         Valid: $(_ebt_router_names_help)"
                cat <<'HELPBODY'
    --unique, -u         Only show rules unique to selected routers
    --chain, -c CHAIN    Filter by chain (INPUT, FORWARD, OUTPUT)
    --refresh, -r        Refresh MAC mapping before report
    --maskmac, -m        Mask last two octets of MAC addresses (xx:xx)
    --count [MIN]        Show packet/byte counters (highlighted in magenta)
                         If MIN is specified, only show rules with packet
                         count >= MIN (useful for finding active rules)
    --no-color, -n       Disable colored output
    --help, -h           Show this help

EXAMPLES
    ebt-report                     Show all rules from all routers
    ebt-report -R primary          Show rules from primary router only
    ebt-report -R mesh1 -R mesh2   Compare two mesh nodes
    ebt-report --unique            Show only rules that differ between routers
    ebt-report -c FORWARD          Show only FORWARD chain rules
    ebt-report --maskmac           Show rules with masked MAC addresses
    ebt-report --count             Show all rules with packet/byte counters
    ebt-report --count 10          Show only rules with >= 10 packet hits
    ebt-report --count 1           Show only rules that have been triggered

CONFIGURATION
    Edit the USER CONFIGURATION section at the top of ebt.zsh:

    _EBT_ROUTERS - Define your routers as IP -> "Model (Shortname)"
        - The shortname in parentheses is used for -R option and MAC labels
        - IMPORTANT: One router MUST include "Primary" in its description
          (e.g., "(Primary)" or "(Main-Primary)"). This router is used as the
          source for DHCP/dnsmasq data when building MAC-to-hostname mappings.
          Typically this is your main AiMesh router, not a mesh node.
        Example:
            _EBT_ROUTERS=(
                "192.168.1.1" "RT-AX88U (Primary)"
                "192.168.1.2" "RT-AX86U (Node1)"
            )

    _EBT_ROUTER_SSH - SSH command for each router IP
        - Must accept a command string as the final argument
        - Username comes from environment variables (set in .zshrc):
            EBT_SSH_USER_<SHORTNAME>  per-router (e.g., EBT_SSH_USER_PRIMARY)
            EBT_SSH_USER              fallback for all routers (default: admin)
        Example:
            _EBT_ROUTER_SSH=(
                "192.168.1.1" "ssh $(_ebt_get_ssh_user 192.168.1.1)@192.168.1.1"
                "192.168.1.2" "ssh -p 2222 $(_ebt_get_ssh_user 192.168.1.2)@192.168.1.2"
            )

RELATED COMMANDS
    ebt-raw [ROUTER]    Show raw ebtables output from a single router
    map_macs            Rebuild the MAC-to-hostname mapping file
    map_macs_show       Display the current MAC mapping

COMPATIBILITY
    Shell:     zsh required (uses zsh-specific syntax)
    Firmware:  Asuswrt-Merlin (tested on 3004.388.x and 3006.102.x)
    Platforms: macOS, Linux, Windows+WSL (with zsh installed)
               NOT compatible with bash, Git Bash, or PowerShell
HELPBODY
                return 0
                ;;
            *) shift ;;
        esac
    done

    # Build the list of routers to query
    typeset -A active_routers
    if [[ ${#selected_routers} -eq 0 ]]; then
        # No filter - use all routers
        for ip in ${(k)_EBT_ROUTERS}; do
            active_routers[$ip]="${_EBT_ROUTERS[$ip]}"
        done
    else
        # Use only selected routers
        for ip in "${selected_routers[@]}"; do
            if [[ -n "${_EBT_ROUTERS[$ip]}" ]]; then
                active_routers[$ip]="${_EBT_ROUTERS[$ip]}"
            fi
        done
    fi

    local active_count=${#active_routers}

    # If only one router, --unique is meaningless
    if [[ $active_count -eq 1 && "$unique_only" == "true" ]]; then
        echo "${_EBT_COLORS[yellow]}Note: --unique ignored (only one router selected)${_EBT_COLORS[reset]}"
        unique_only=false
    fi

    echo "${_EBT_COLORS[bold]}Fetching ebtables from routers...${_EBT_COLORS[reset]}"

    # Build hostname cache (from macmap.tmp, or refresh if requested/missing)
    echo "  Loading hostname cache..."
    _ebt_build_hostname_cache "$refresh_macs"

    # Fetch ebtables from selected routers (both filter and nat tables)
    typeset -A router_data
    for ip in ${(k)active_routers}; do
        echo "  Fetching from $ip (${active_routers[$ip]})..."
        local ebt_opts="-L"
        [[ "$show_count" == "true" ]] && ebt_opts="-L --Lc"
        local filter_data=$(_ebt_ssh "$ip" "ebtables $ebt_opts")
        local nat_data=$(_ebt_ssh "$ip" "ebtables -t nat $ebt_opts")
        # Combine both tables, prefixing nat chains to distinguish them
        router_data[$ip]="${filter_data}"$'\n'"${nat_data}"
    done

    # First pass: identify common rules (present on all selected routers)
    # Build a set of normalized rules per router
    typeset -A rules_by_router  # ip -> newline-separated list of "chain|norm_rule"
    local router_count=${#active_routers}

    for ip in ${(k)active_routers}; do
        local current_chain=""
        local rules_list=""

        while IFS= read -r line; do
            case "$line" in
                "Bridge chain: "*)
                    current_chain=$(echo "$line" | sed 's/Bridge chain: \([^,]*\).*/\1/')
                    ;;
                "-"*)
                    [[ -z "$current_chain" ]] && continue
                    [[ -n "$filter_chain" && "$current_chain" != "$filter_chain" ]] && continue

                    local norm_rule=$(_ebt_normalize_rule "$line")
                    local key="$current_chain|$norm_rule"
                    rules_list+="$key"$'\n'
                    ;;
            esac
        done <<< "${router_data[$ip]}"

        rules_by_router[$ip]="$rules_list"
    done

    # Count occurrences of each rule across routers
    typeset -A rule_counts
    for ip in ${(k)active_routers}; do
        echo "${rules_by_router[$ip]}" | while IFS= read -r key; do
            [[ -z "$key" ]] && continue
            if [[ -z "${rule_counts[$key]}" ]]; then
                rule_counts[$key]=1
            else
                rule_counts[$key]=$((rule_counts[$key] + 1))
            fi
        done
    done

    # Build set of common rules (for --unique filtering)
    typeset -A common_rules
    for key in ${(k)rule_counts}; do
        if [[ "${rule_counts[$key]}" -eq $router_count ]]; then
            common_rules[$key]=1
        fi
    done

    # Display each router's rules in original order
    local total_common=0
    local -A unique_counts
    local -A total_counts

    for ip in ${(ko)active_routers}; do
        local router_name="${active_routers[$ip]}"
        local current_chain=""
        local header_shown=false
        local unique_count=0
        local total_count=0

        # Collect rules for this router to calculate padding
        local -a display_rules  # array of "chain|original_rule|is_common"

        while IFS= read -r line; do
            case "$line" in
                "Bridge chain: "*)
                    current_chain=$(echo "$line" | sed 's/Bridge chain: \([^,]*\).*/\1/')
                    ;;
                "-"*)
                    [[ -z "$current_chain" ]] && continue
                    [[ -n "$filter_chain" && "$current_chain" != "$filter_chain" ]] && continue

                    local norm_rule=$(_ebt_normalize_rule "$line")
                    local key="$current_chain|$norm_rule"
                    local is_common=0
                    [[ -n "${common_rules[$key]}" ]] && is_common=1

                    # Filter by minimum packet count if --count with threshold is specified
                    if [[ "$show_count" == "true" && $min_count -gt 0 ]]; then
                        local pcnt=$(_ebt_get_pcnt "$line")
                        if [[ $pcnt -lt $min_count ]]; then
                            continue
                        fi
                    fi

                    display_rules+=("$current_chain|$line|$is_common")
                    ((total_count++))
                    [[ $is_common -eq 0 ]] && ((unique_count++))
                    ;;
            esac
        done <<< "${router_data[$ip]}"

        unique_counts[$ip]=$unique_count
        total_counts[$ip]=$total_count

        # Calculate max source width for padding
        local max_src_width=0
        for entry in "${display_rules[@]}"; do
            local rule="${entry#*|}"
            rule="${rule%|*}"
            local src_text=$(_ebt_get_src_text "$rule" "$mask_mac")
            local src_len=${#src_text}
            [[ $src_len -gt $max_src_width ]] && max_src_width=$src_len
        done

        # Display rules
        local last_chain=""
        local displayed_count=0

        for entry in "${display_rules[@]}"; do
            local chain="${entry%%|*}"
            local rest="${entry#*|}"
            local rule="${rest%|*}"
            local is_common="${rest##*|}"

            # Skip common rules if --unique flag is set
            if [[ "$unique_only" == "true" && "$is_common" -eq 1 ]]; then
                continue
            fi

            # Show header on first rule
            if [[ "$header_shown" == "false" ]]; then
                if [[ "$unique_only" == "true" ]]; then
                    _ebt_header "$router_name ($ip) - UNIQUE RULES" "$use_color"
                else
                    _ebt_header "$router_name ($ip)" "$use_color"
                fi
                header_shown=true
            fi

            # Show chain subheader when chain changes
            if [[ "$chain" != "$last_chain" ]]; then
                _ebt_subheader "Chain: $chain" "$use_color"
                last_chain="$chain"
            fi

            # Format and display the rule
            local prefix=""
            if [[ "$unique_only" == "false" && "$is_common" -eq 1 ]]; then
                # Mark common rules with a subtle indicator
                if [[ "$use_color" == "true" ]]; then
                    prefix="${_EBT_COLORS[dim]}● ${_EBT_COLORS[reset]}"
                else
                    prefix="● "
                fi
            else
                prefix="  "
            fi

            echo "${prefix}$(_ebt_format_rule "$rule" "$use_color" "$max_src_width" "$mask_mac")"
            ((displayed_count++))
        done

        # Show message if no rules to display for this router
        if [[ "$header_shown" == "false" && "$unique_only" == "true" && $total_count -gt 0 ]]; then
            _ebt_header "$router_name ($ip) - UNIQUE RULES" "$use_color"
            echo "  ${_EBT_COLORS[dim]}(no unique rules)${_EBT_COLORS[reset]}"
        fi

        display_rules=()
    done

    # Summary
    echo ""
    if [[ "$use_color" == "true" ]]; then
        echo "${_EBT_COLORS[bold]}${_EBT_COLORS[green]}Summary:${_EBT_COLORS[reset]}"
    else
        echo "Summary:"
    fi
    if [[ $active_count -gt 1 ]]; then
        echo "  Common rules (all $active_count routers): ${#common_rules}"
    fi
    for ip in ${(ko)active_routers}; do
        if [[ $active_count -gt 1 ]]; then
            echo "  ${active_routers[$ip]} unique: ${unique_counts[$ip]:-0}"
        else
            echo "  ${active_routers[$ip]} total rules: ${total_counts[$ip]:-0}"
        fi
    done
    if [[ "$unique_only" == "true" ]]; then
        echo ""
        echo "  ${_EBT_COLORS[dim]}(showing unique rules only)${_EBT_COLORS[reset]}"
    elif [[ $active_count -gt 1 ]]; then
        echo ""
        echo "  ${_EBT_COLORS[dim]}● = common rule (present on all selected routers)${_EBT_COLORS[reset]}"
    fi
    if [[ "$show_count" == "true" && $min_count -gt 0 ]]; then
        echo "  ${_EBT_COLORS[dim]}(filtered: showing rules with pcnt >= $min_count)${_EBT_COLORS[reset]}"
    fi
}

# Quick alias for just viewing raw ebtables from one router
ebt-raw() {
    local target="${1:-$(_ebt_get_primary)}"

    # Resolve name to IP if needed
    local ip=$(_ebt_resolve_router "$target")
    if [[ -z "$ip" ]]; then
        echo "Unknown router: $target"
        echo "Valid: $(_ebt_router_names_help)"
        return 1
    fi

    echo "Fetching ebtables from $ip (${_EBT_ROUTERS[$ip]})..."
    echo ""
    echo "=== Filter Table ==="
    _ebt_ssh "$ip" "ebtables -L"
    echo ""
    echo "=== NAT Table ==="
    _ebt_ssh "$ip" "ebtables -t nat -L"
}

# Band number to friendly name
_ebt_band_name() {
    case "$1" in
        1) echo "5G" ;;
        2) echo "2.4G" ;;
        4) echo "6G" ;;
        *) echo "WiFi" ;;
    esac
}

# Build comprehensive MAC mapping file
# Sources (in priority order):
#   1. dnsmasq.conf static DHCP entries (authoritative)
#   2. dnsmasq.leases dynamic entries (fill gaps)
#   3. Router infrastructure MACs (backhaul, fronthaul, wifi)
map_macs() {
    local macmap="$_EBT_MACMAP_FILE"
    local tmpdir="${TMPDIR:-/tmp}"
    local dnsmasq_conf="$tmpdir/macmap_dnsmasq_$$"
    local dnsmasq_leases="$tmpdir/macmap_leases_$$"
    local primary_ip=$(_ebt_get_primary)

    echo "${_EBT_COLORS[bold]}Building MAC mapping file...${_EBT_COLORS[reset]}"

    # Remove existing file
    rm -f "$macmap" 2>/dev/null
    touch "$macmap"

    # === Step 1: Parse dnsmasq.conf for static DHCP entries ===
    echo "  Fetching dnsmasq.conf from primary router ($primary_ip)..."
    _ebt_ssh "$primary_ip" "cat /tmp/etc/dnsmasq.conf" > "$dnsmasq_conf" 2>/dev/null

    # Parse dhcp-host=MAC,hostname[,IP] or dhcp-host=MAC,IP,hostname
    grep "^dhcp-host=" "$dnsmasq_conf" 2>/dev/null | while IFS='=' read -r _ value; do
        local mac=$(echo "$value" | cut -d',' -f1)
        local field2=$(echo "$value" | cut -d',' -f2)
        local field3=$(echo "$value" | cut -d',' -f3)
        [[ -z "$mac" ]] && continue

        # Determine which field is the hostname (not an IP address)
        local hostname=""
        if [[ -n "$field2" && ! "$field2" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            hostname="$field2"
        elif [[ -n "$field3" && ! "$field3" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            hostname="$field3"
        fi

        local norm_mac=$(_ebt_normalize_mac "$mac")
        if [[ -n "$hostname" ]]; then
            echo "${norm_mac}\t${hostname}" >> "$macmap"
        else
            echo "${norm_mac}\t" >> "$macmap"
        fi
    done

    local static_count=$(wc -l < "$macmap" | tr -d ' ')
    echo "    Found $static_count static DHCP entries"

    # === Step 2: Parse dnsmasq.leases for dynamic entries ===
    echo "  Fetching dnsmasq.leases from primary router..."
    _ebt_ssh "$primary_ip" "cat /var/lib/misc/dnsmasq.leases 2>/dev/null || cat /tmp/dnsmasq.leases 2>/dev/null" \
        > "$dnsmasq_leases" 2>/dev/null

    local added=0
    local updated=0

    # Format: timestamp mac ip hostname client_id
    while IFS=' ' read -r ts mac ip hostname rest; do
        [[ -z "$mac" || "$mac" == "#"* ]] && continue
        local norm_mac=$(_ebt_normalize_mac "$mac")

        # Check if MAC already exists in mapping
        local existing=$(grep "^${norm_mac}" "$macmap" 2>/dev/null)

        if [[ -z "$existing" ]]; then
            # New MAC - add it
            if [[ -n "$hostname" && "$hostname" != "*" ]]; then
                echo "${norm_mac}\t${hostname}" >> "$macmap"
            else
                echo "${norm_mac}\t" >> "$macmap"
            fi
            ((added++))
        else
            # MAC exists - check if we should update hostname
            local existing_hostname=$(echo "$existing" | cut -f2)
            if [[ -z "$existing_hostname" && -n "$hostname" && "$hostname" != "*" ]]; then
                # Update blank hostname with lease hostname
                sed -i '' "s/^${norm_mac}\t.*$/${norm_mac}\t${hostname}/" "$macmap"
                ((updated++))
            fi
        fi
    done < "$dnsmasq_leases"

    echo "    Added $added from leases, updated $updated hostnames"

    # === Step 3: Add router infrastructure MACs ===
    echo "  Fetching infrastructure MACs from routers..."

    for ip in ${(k)_EBT_ROUTERS}; do
        local shortname=$(_ebt_get_shortname "$ip")
        echo "    Querying $shortname ($ip)..."

        # Get base ethernet MAC
        local base_mac=$(_ebt_ssh "$ip" "nvram get et0macaddr")

        if [[ -n "$base_mac" ]]; then
            local norm_base=$(_ebt_normalize_mac "$base_mac")
            if ! grep -q "^${norm_base}" "$macmap" 2>/dev/null; then
                echo "${norm_base}\t${shortname}" >> "$macmap"
            fi
        fi

        # Get wireless interface MACs with their bands
        # Query for wl0, wl1, wl2 and their .1, .2 variants
        local wl_data=$(_ebt_ssh "$ip" '
            for band in 0 1 2; do
                hwaddr=$(nvram get wl${band}_hwaddr)
                nband=$(nvram get wl${band}_nband)
                ssid=$(nvram get wl${band}_ssid)
                [ -n "$hwaddr" ] && echo "wl${band}|${hwaddr}|${nband}|${ssid}|0"

                # Check .1, .2, .3 variants (virtual AP interfaces)
                for sub in 1 2 3; do
                    hwaddr=$(nvram get wl${band}.${sub}_hwaddr)
                    ssid=$(nvram get wl${band}.${sub}_ssid)
                    [ -n "$hwaddr" ] && [ "$hwaddr" != "00:00:00:00:00:00" ] && \
                        echo "wl${band}.${sub}|${hwaddr}|${nband}|${ssid}|${sub}"
                done
            done
        ')

        # Process wireless interfaces
        echo "$wl_data" | while IFS='|' read -r iface hwaddr nband ssid subidx; do
            [[ -z "$hwaddr" ]] && continue
            local norm_mac=$(_ebt_normalize_mac "$hwaddr")

            # Skip if already mapped
            grep -q "^${norm_mac}" "$macmap" 2>/dev/null && continue

            local band_name=$(_ebt_band_name "$nband")
            local label=""
            local vap_suffix=""

            # Add vap suffix for subinterfaces (.2, .3, etc.) but not for base or .1
            if [[ "$subidx" -ge 2 ]]; then
                vap_suffix="-vap${subidx}"
            fi

            # Determine if fronthaul (user-facing SSID) or backhaul (mesh SSID)
            # AiMesh backhaul uses a 32-character hex string as hidden SSID
            if [[ "$ssid" =~ ^[A-F0-9]{32}$ ]]; then
                # Backhaul - hidden mesh network
                label="${shortname}-${band_name}-BH${vap_suffix}"
            else
                # Fronthaul or other user-facing network
                label="${shortname}-${band_name}${vap_suffix}"
            fi

            echo "${norm_mac}\t${label}" >> "$macmap"
        done
    done

    # Cleanup temp files
    rm -f "$dnsmasq_conf" "$dnsmasq_leases" 2>/dev/null

    # Summary
    local total=$(wc -l < "$macmap" | tr -d ' ')
    echo ""
    echo "${_EBT_COLORS[green]}MAC mapping complete: $total entries in $macmap${_EBT_COLORS[reset]}"
}

# View the current MAC mapping file
map_macs_show() {
    local macmap="$_EBT_MACMAP_FILE"

    if [[ ! -f "$macmap" ]]; then
        echo "MAC mapping file not found. Run 'map_macs' first."
        return 1
    fi

    echo "${_EBT_COLORS[bold]}MAC Mapping File: $macmap${_EBT_COLORS[reset]}"
    echo "${_EBT_COLORS[dim]}$(wc -l < "$macmap" | tr -d ' ') entries${_EBT_COLORS[reset]}"
    echo ""

    # Display sorted by hostname
    sort -t$'\t' -k2 "$macmap" | while IFS=$'\t' read -r mac hostname; do
        if [[ -n "$hostname" ]]; then
            printf "${_EBT_COLORS[cyan]}%-20s${_EBT_COLORS[reset]} %s\n" "$mac" "$hostname"
        else
            printf "${_EBT_COLORS[cyan]}%-20s${_EBT_COLORS[reset]} ${_EBT_COLORS[dim]}(unnamed)${_EBT_COLORS[reset]}\n" "$mac"
        fi
    done
}
