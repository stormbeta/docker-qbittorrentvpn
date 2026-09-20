#!/bin/bash
# Forked from binhex's OpenVPN dockers
#
# Builds the container firewall as a single nftables table. The whole ruleset is
# applied in one atomic transaction, so there is never a window where the chain
# policy is 'drop' but the accept rules have not landed yet.
set -e

# Wait until the tunnel interface the VPN layer told us about actually exists.
while ! ip -j link show dev "${VPN_DEVICE_TYPE}" &> /dev/null; do
	sleep 1
done

# identify the bridge interface, its network and the default gateway
docker_interface=$(ip -j -4 route show default | jq -r '.[0].dev // empty')
if [[ -z "${docker_interface}" ]]; then
	echo "[ERROR] Unable to determine the default route interface, exiting..." | ts '%Y-%m-%d %H:%M:%.S'
	sleep 10
	exit 1
fi

DEFAULT_GATEWAY=$(ip -j -4 route show default | jq -r '.[0].gateway // empty')
docker_ip=$(ip -j -4 addr show dev "${docker_interface}" | jq -r '.[0].addr_info[0].local // empty')
docker_network_cidr=$(ip -j -4 addr show dev "${docker_interface}" \
	| jq -r '.[0].addr_info[0] | select(.local != null) | "\(.local)/\(.prefixlen)"')

if [[ -z "${docker_network_cidr}" || -z "${DEFAULT_GATEWAY}" ]]; then
	echo "[ERROR] Unable to determine the network for ${docker_interface}, exiting..." | ts '%Y-%m-%d %H:%M:%.S'
	sleep 10
	exit 1
fi

if [[ "${DEBUG}" == "true" ]]; then
	echo "[DEBUG] Docker interface defined as ${docker_interface}" | ts '%Y-%m-%d %H:%M:%.S'
	echo "[DEBUG] Docker IP defined as ${docker_ip}" | ts '%Y-%m-%d %H:%M:%.S'
	echo "[DEBUG] Default gateway defined as ${DEFAULT_GATEWAY}" | ts '%Y-%m-%d %H:%M:%.S'
fi

echo "[INFO] Docker network defined as ${docker_network_cidr}" | ts '%Y-%m-%d %H:%M:%.S'

# ip route
###

# split comma separated string into list from LAN_NETWORK env variable
IFS=',' read -ra lan_network_list <<< "${LAN_NETWORK}"

# process lan networks in the list
for lan_network_item in "${lan_network_list[@]}"; do
	# strip whitespace from start and end of lan_network_item
	lan_network_item=$(echo "${lan_network_item}" | sed -e 's~^[ \t]*~~;s~[ \t]*$~~')

	echo "[INFO] Adding ${lan_network_item} as route via ${docker_interface}" | ts '%Y-%m-%d %H:%M:%.S'
	ip route replace "${lan_network_item}" via "${DEFAULT_GATEWAY}" dev "${docker_interface}"
done

echo "[INFO] ip route defined as follows..." | ts '%Y-%m-%d %H:%M:%.S'
echo "--------------------"
ip route
echo "--------------------"

# policy route for the WebUI, so replies to LAN clients leave via the bridge
# rather than being swallowed by the tunnel's default route
###

# Referenced by number rather than by a name in /etc/iproute2/rt_tables, which
# Debian no longer ships. The old script also registered the same 'webui' name
# against two different table ids, which made the name ambiguous.
webui_table=8080

ip rule list | grep -q "fwmark 0x1 lookup ${webui_table}" \
	|| ip rule add fwmark 1 table "${webui_table}"
ip route replace default via "${DEFAULT_GATEWAY}" dev "${docker_interface}" table "${webui_table}"

# build the port lists used by the ruleset
###

# 8080 is the WebUI; ADDITIONAL_PORTS is user supplied, so only accept integers
webui_ports=("8080")
if [[ -n "${ADDITIONAL_PORTS}" ]]; then
	IFS=',' read -ra additional_port_list <<< "${ADDITIONAL_PORTS}"
	for additional_port_item in "${additional_port_list[@]}"; do
		additional_port_item=$(echo "${additional_port_item}" | sed -e 's~^[ \t]*~~;s~[ \t]*$~~')
		if [[ "${additional_port_item}" =~ ^[0-9]+$ ]] && (( additional_port_item > 0 && additional_port_item < 65536 )); then
			echo "[INFO] Adding additional port ${additional_port_item} for ${docker_interface}" | ts '%Y-%m-%d %H:%M:%.S'
			webui_ports+=("${additional_port_item}")
		else
			echo "[WARNING] Ignoring invalid ADDITIONAL_PORTS entry '${additional_port_item}'" | ts '%Y-%m-%d %H:%M:%.S'
		fi
	done
fi
# join into an nft set body, e.g. "8080, 1234"
tcp_ports=$(IFS=','; echo "${webui_ports[*]}" | sed 's~,~, ~g')

# restrict the VPN handshake to the actual endpoint where we can, so a
# compromised or misbehaving client cannot use the hole for arbitrary traffic
if [[ "${VPN_REMOTE}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
	vpn_endpoint_match="ip daddr ${VPN_REMOTE} "
	vpn_endpoint_match_in="ip saddr ${VPN_REMOTE} "
else
	echo "[WARNING] VPN_REMOTE '${VPN_REMOTE}' is not a literal IP, leaving the VPN port open to any destination" | ts '%Y-%m-%d %H:%M:%.S'
	vpn_endpoint_match=""
	vpn_endpoint_match_in=""
fi

# nftables ruleset
###

# The empty table declaration makes the delete safe when nothing exists yet.
# All three statements are one transaction: it applies whole or not at all.
nft -f - <<EOF
table inet qbtvpn {}
delete table inet qbtvpn

table inet qbtvpn {
	chain input {
		type filter hook input priority filter; policy drop;

		# loopback first, so it stays reachable over v6 as well
		iif lo accept

		# IPv6 is not carried by this container
		meta nfproto ipv6 drop

		# anything arriving over the tunnel
		iifname "${VPN_DEVICE_TYPE}" accept

		# traffic within the container network
		iifname "${docker_interface}" ip saddr ${docker_network_cidr} accept

		# return traffic from the VPN endpoint
		iifname "${docker_interface}" ${vpn_endpoint_match_in}${VPN_PROTOCOL} sport ${VPN_PORT} accept

		# WebUI and any additional ports, from the LAN only
		iifname "${docker_interface}" tcp dport { ${tcp_ports} } accept
		iifname "${docker_interface}" tcp sport { ${tcp_ports} } accept

		# ping replies, tunnel only - the health check depends on this
		iifname "${VPN_DEVICE_TYPE}" icmp type echo-reply accept

		counter comment "input-leak-drop"
	}

	chain output {
		type filter hook output priority filter; policy drop;

		oif lo accept

		meta nfproto ipv6 drop

		# anything leaving over the tunnel
		oifname "${VPN_DEVICE_TYPE}" accept

		# traffic within the container network
		oifname "${docker_interface}" ip daddr ${docker_network_cidr} accept

		# the VPN handshake itself
		oifname "${docker_interface}" ${vpn_endpoint_match}${VPN_PROTOCOL} dport ${VPN_PORT} accept

		# WebUI and any additional ports, to the LAN only
		oifname "${docker_interface}" tcp dport { ${tcp_ports} } accept
		oifname "${docker_interface}" tcp sport { ${tcp_ports} } accept

		# ping requests, tunnel only - without this restriction the health
		# check succeeds over the bare interface when the tunnel is down
		oifname "${VPN_DEVICE_TYPE}" icmp type echo-request accept

		counter comment "output-leak-drop"
	}

	chain mark_webui {
		# 'route' rather than 'filter' so the mark triggers a re-route check,
		# which is what makes the 'webui' routing table above take effect
		type route hook output priority mangle;

		tcp sport 8080 meta mark set 1
		tcp dport 8080 meta mark set 1
	}
}
EOF

echo "[INFO] nftables ruleset defined as follows..." | ts '%Y-%m-%d %H:%M:%.S'
echo "--------------------"
nft list table inet qbtvpn
echo "--------------------"

exec /bin/bash /etc/qbittorrent/start.sh
