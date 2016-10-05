#!/bin/sh
#

ss_local_port=12345
ss_server_ip1=52.197.156.235
#ss_server_ip2=52.193.77.21


#./ss-rules -f


# if [[ "$verb" == "stop" ]]; then
# 	# The rules have all been cleared; now is a good time to exit
# 	exit
# fi





#exit



verb=$1

killall ss-redir 2> /dev/null


# Reset to known, clean state
iptables -t nat -N SHADOWSOCKS 2> /dev/null
#iptables -t mangle -N SHADOWSOCKS
iptables -t nat -F SHADOWSOCKS 2> /dev/null
#iptables -t mangle -F SHADOWSOCKS

iptables -t nat -D PREROUTING -p tcp -j SHADOWSOCKS 2> /dev/null
#iptables -t mangle -D PREROUTING -j SHADOWSOCKS > /dev/null

if [[ "$verb" == "stop" ]]; then
	# The rules have all been cleared; now is a good time to exit
	exit
fi


set -e

# Start the shadowsocks-redir
# Do it here so that in case it fails, we don't end up with a broken iptables configuration
ss-redir -v -c /mnt/usb/bin/ss-redir.json -f /var/run/shadowsocks.pid &
#ss-redir -u   # if you need UDP redirection

# Ignore your shadowsocks server's addresses
# It's very IMPORTANT, just be careful.
iptables -t nat -A SHADOWSOCKS -d $ss_server_ip1 -j RETURN

# Ignore LANs and any other addresses you'd like to bypass the proxy
# See Wikipedia and RFC5735 for full list of reserved networks.
iptables -t nat -A SHADOWSOCKS -d 0.0.0.0/8 -j RETURN
iptables -t nat -A SHADOWSOCKS -d 10.0.0.0/8 -j RETURN
iptables -t nat -A SHADOWSOCKS -d 127.0.0.0/8 -j RETURN
iptables -t nat -A SHADOWSOCKS -d 169.254.0.0/16 -j RETURN
iptables -t nat -A SHADOWSOCKS -d 172.16.0.0/12 -j RETURN
iptables -t nat -A SHADOWSOCKS -d 192.168.0.0/16 -j RETURN
iptables -t nat -A SHADOWSOCKS -d 224.0.0.0/4 -j RETURN
iptables -t nat -A SHADOWSOCKS -d 240.0.0.0/4 -j RETURN

# TODO: add China's IP ranges here
# Working with ipset:
# http://daemonkeeper.net/781/mass-blocking-ip-addresses-with-ipset/
# See ashi009/bestroutetb for a highly optimized CHN route list.

# Anything else should be redirected to shadowsocks's local port
iptables -t nat -A SHADOWSOCKS -p tcp -j REDIRECT --to-ports $ss_local_port

# Add any UDP rules
#ip route add local default dev lo table 100
#ip rule add fwmark 1 lookup 100
#iptables -t mangle -A SHADOWSOCKS -p udp --dport 53 -j TPROXY --on-port 12345 --tproxy-mark 0x01/0x01
#iptables -t mangle -A SHADOWSOCKS_MARK -p udp --dport 53 -j MARK --set-mark 1

# Apply the rules
iptables -t nat -I PREROUTING -p tcp -j SHADOWSOCKS
#iptables -t mangle -I PREROUTING -j SHADOWSOCKS
#iptables -t mangle -A OUTPUT -j SHADOWSOCKS_MARK

