# ASUS Merlin Shell Utilities

A collection of shell utility functions for managing and interacting with ASUS routers running [Asuswrt-Merlin](https://www.asuswrt-merlin.net/) firmware.

## Overview

This project provides shell functions that make it easier to:

- View and compare ebtables (Layer 2 firewall) rules across AiMesh routers
- Resolve MAC addresses to hostnames using DHCP data
- Identify common vs unique rules across mesh nodes

<p align="center">
  <img src="/readme_images/ebt-report.png?raw=true" alt="ebt-table output" width="45%"/>
  <img src="/readme_images/ebt-report-end.png?raw=true" alt="ebt-table output" width="45%"/>
</p>


## Shell Support

| Shell | Status |
|-------|--------|
| zsh | Supported |
| bash | Planned |
| PowerShell | Not planned |

## Platform Compatibility

| Platform | Status | Notes |
|----------|--------|-------|
| macOS | Works out of the box | zsh is the default shell |
| Linux | Works | Install zsh: `apt install zsh` or `yum install zsh` |
| Windows + WSL | Works | Install zsh in WSL: `apt install zsh` |
| Windows + Git Bash | Not compatible | Uses bash, not zsh |
| PowerShell | Not compatible | |

## Firmware Compatibility

Tested on:
- Asuswrt-Merlin 3004.388.x
- Asuswrt-Merlin 3006.102.x

Should work on any Asuswrt-Merlin firmware with ebtables support.

## Installation

### 1. Clone the repository

```bash
git clone https://github.com/yourusername/asus-merlin-shell-utilities.git
cd asus-merlin-shell-utilities
```

### 2. Source `ebt.zsh` in your `.zshrc`

Add the following line to your `~/.zshrc` file:

```zsh
# ASUS Merlin Shell Utilities
source /path/to/asus-merlin-shell-utilities/zsh/ebt.zsh
```

Or if you cloned to a standard location:

```zsh
# ASUS Merlin Shell Utilities
source ~/projects/asus-merlin-shell-utilities/zsh/ebt.zsh
```

### 3. Reload your shell

```bash
source ~/.zshrc
```

Or simply open a new terminal window.

## Configuration

Before using the utilities, edit the **USER CONFIGURATION** section at the top of `zsh/ebt.zsh`:

### Router Definitions

Define your routers with their IP addresses and descriptions:

```zsh
typeset -gA _EBT_ROUTERS
_EBT_ROUTERS=(
    "192.168.1.1" "RT-AX88U (Primary)"
    "192.168.1.2" "RT-AX86U (Node1)"
    "192.168.1.3" "RT-AX88U-Pro (Node2)"
)
```

**Important:** One router MUST include `Primary` in its description. This router is used as the source for DHCP/dnsmasq data when building MAC-to-hostname mappings. Typically this is your main AiMesh router.

### SSH Configuration

Define the SSH command for each router. The username is read from environment variables:

```zsh
typeset -gA _EBT_ROUTER_SSH
_EBT_ROUTER_SSH=(
    "192.168.1.1" "ssh $(_ebt_get_ssh_user 192.168.1.1)@192.168.1.1"
    "192.168.1.2" "ssh -p 2222 $(_ebt_get_ssh_user 192.168.1.2)@192.168.1.2"
    "192.168.1.3" "ssh -i ~/.ssh/router_key $(_ebt_get_ssh_user 192.168.1.3)@192.168.1.3"
)
```

### SSH Username Environment Variables

Set these in your `~/.zshrc` **before** sourcing `ebt.zsh`:

```zsh
# Per-router usernames (based on shortnames in _EBT_ROUTERS)
export EBT_SSH_USER_PRIMARY="admin"
export EBT_SSH_USER_NODE1="admin"
export EBT_SSH_USER_NODE2="admin"

# Or use a single username for all routers:
export EBT_SSH_USER="admin"
```

The username lookup order is:
1. `EBT_SSH_USER_<SHORTNAME>` (e.g., `EBT_SSH_USER_PRIMARY` for a router with shortname "Primary")
2. `EBT_SSH_USER` (fallback for all routers)
3. `"admin"` (default if no env vars set)

### Prerequisites

- SSH access to your router(s) with key-based or password authentication
- Router(s) running Asuswrt-Merlin firmware with ebtables support

## Available Commands

### `ebt-report`

Display and compare ebtables rules across AiMesh routers with MAC address resolution to hostnames.

```bash
# Show all rules from all routers
ebt-report

# Show rules from primary router only
ebt-report -R primary

# Compare two mesh nodes
ebt-report -R node1 -R node2

# Show only rules that differ between routers
ebt-report --unique

# Show only FORWARD chain rules
ebt-report -c FORWARD

# Refresh MAC mapping before report
ebt-report --refresh

# Disable colored output
ebt-report --no-color
```

**Options:**
| Option | Description |
|--------|-------------|
| `-R, --router ROUTER` | Include specific router (can be repeated) |
| `-u, --unique` | Only show rules unique to selected routers |
| `-c, --chain CHAIN` | Filter by chain (INPUT, FORWARD, OUTPUT) |
| `-r, --refresh` | Refresh MAC mapping before report |
| `-m, --maskmac` | Mask last two octets of MAC addresses (xx:xx) |
| `--count [MIN]` | Show packet/byte counters; optionally filter by minimum packet count |
| `-n, --no-color` | Disable colored output |
| `-h, --help` | Show help |

### `ebt-raw`

Show raw ebtables output from a single router.

```bash
# From primary router (default)
ebt-raw

# From a specific router
ebt-raw node1
ebt-raw 192.168.1.2
```

### `map_macs`

Build/rebuild the MAC-to-hostname mapping file. Sources data from:
1. dnsmasq.conf static DHCP entries
2. dnsmasq.leases dynamic entries
3. Router infrastructure MACs (backhaul, fronthaul, wifi interfaces)

### `map_macs_show`

Display the current MAC mapping file sorted by hostname.

```bash
map_macs_show
```

## How It Works

### ebtables Integration

These utilities interact with `ebtables`, the Linux bridge firewall, which operates at Layer 2 (MAC address level). This allows for:

- Complete network isolation of devices
- Traffic control that works regardless of IP address changes
- Blocking that works even for devices that haven't obtained a DHCP lease

### MAC Address Resolution

The `map_macs` function builds a comprehensive mapping of MAC addresses to hostnames by querying:

1. **Static DHCP entries** from `/tmp/etc/dnsmasq.conf`
2. **Dynamic DHCP leases** from `/var/lib/misc/dnsmasq.leases`
3. **Router wireless interfaces** including backhaul and fronthaul MACs

This mapping is cached locally in `~/.ebt_macmap.tmp` for quick lookups.

## Examples

### View ebtables rules with hostname resolution

```
$ ebt-report -R primary

════════════════════════════════════════════════════════════════════════════════
  RT-BE92U (Primary) (10.10.3.1)
════════════════════════════════════════════════════════════════════════════════

── Chain: FORWARD ──

  -s aa:bb:cc:dd:ee:ff (iPhone-John) -j DROP  # Block from this source
  -d aa:bb:cc:dd:ee:ff (iPhone-John) -j DROP  # Block to this dest
```

## Contributing

Contributions are welcome! This project is in early development and community feedback from the Asuswrt-Merlin community is appreciated.

### Areas for contribution:
- bash shell support
- Additional utility functions
- Documentation improvements
- Testing on different router models

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [Asuswrt-Merlin](https://www.asuswrt-merlin.net/) - The enhanced firmware that makes these utilities possible
- The Asuswrt-Merlin community on [SNBForums](https://www.snbforums.com/forums/asuswrt-merlin.42/)
