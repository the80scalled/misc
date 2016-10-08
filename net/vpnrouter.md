Turning an RT-N66U into an awesome VPN router
=============================================

It takes a long time (less if you have this guide), but it's worth it.

### Firmware

There's no stock firmware out there with support for shadowsocks, so you have to go custom. There are basically five options here:

-	A Chinese-made custom build with shadowsocks and everything already built in. The problem is that they're in Chinese and if something breaks, you'll have to spend time fixing it, which may or may not be possible.
-	OpenWRT. Most of the shadowsocks articles focus around this option. The problem is that OpenWRT is [basically broken](https://dev.openwrt.org/ticket/10852#comment:49) on the RT-N66U, and there are no plans to fix it.
-	Tomato. Here there are a few options, such as Advanced Tomato and TomatoUSB. I tried both and found that the former couldn't keep an internet connection up for more than a few hours, and found the latter to be riddled with bugs.
-	DD-WRT. I didn't try this because the RT-N66U's page on the DD-WRT wiki didn't exactly fill me with hope. For this particular router, it seems to have better support than OpenWRT, but worse than Tomato.
-	AsusWRT-Merlin. This is basically the stock firmware with a few features and bug fixes added on. I ruled this out early on because dual WAN seemingly didn't support load balancing with failover...except that it does, and it's far more stable than Tomato Shibby's implementation.

The one drawback with AsusWRT-Merlin is that virtual SSIDs aren't configurable under the GUI, but I'll take scriptable and stable over user-friendly and unstable.

If I were going to do this again, I'd search Chinese forums for routers that support OpenWRT.

### Getting started with AsusWRT-Merlin

Flash it, set it up, enable SSH, all that jazz.

Most modern routers use a package management system like apt-get, only lighter. Luckily, they're all mostly compatible, so the ecosystem seems to be stabilizing rather nicely. The flavor du jour is called `entware`, and it needs some extra disk space, so we need to get that set up.

First, find the smallest USB thumbdrive you own (a 1GB micro SD card in a tiny USB adapter works the best), wipe it and delete all partitions, then insert it into the router in the *top slot* (this ensures it doesn't get renamed later). We're going to create a Linux filesystem on it:

1.	`fdisk -l` Lists all physical disks. You should see /dev/sda.
2.	`fdisk /dev/sda`
3.	`p` to print the partition table. Shouldn't have anything on it. If there is, use the commands to delete it.
4.	`n` to create a new partition; select `p`, primary partition; `1` for index = 1.
5.	Select the default start and stop cylinders.
6.	`p` to see your beautiful work. (it's not saved yet!) The partition name should be `/dev/sda1`.
7.	`w` to write the partition table to disk.
8.	`q` to exit.

So now there's a partition on the drive, but it's empty. Like, all zeros empty. We need to fix that by creating a filesystem on it. We'll be using ext3.

```bash
mkfs.ext3 /dev/sda1
mkdir /mnt/sda1
mount /dev/sda1 /mnt/sda1
```

Next, make sure it auto-mounts on startup:

```bash
tee /jffs/configs/fstab <<-EOF
# device mountpoint fstype options dump fsck
/dev/sda1 /mnt/sda1 ext3 defaults 0 1
EOF

tee /jffs/scripts/init-start <<-EOF
#!/bin/sh
mkdir -p /mnt/sda1
EOF

chmod +x /jffs/scripts/init-start
```

And finally, as detailed on [this page](https://github.com/RMerl/asuswrt-merlin/wiki/Entware), no need to be a hero, just use the setup script, which is already in the ROM and part of the $PATH:

```bash
entware-setup.sh
```

And select partition `1`, of course. Congratulations, you now have a persistent /opt folder with entware installed.

Reboot the router to ensure the startup commands to mount the volume work properly.

#### Into the shadows

Install shadowsocks-libev, taking care not to get the deprecated polarssl version:

```
opkg install shadowsocks-libev
```

This is where the real fun begins. We basically need to run `ss-redir`, the transparent proxy version of the shadowsocks client, which can VPNify any traffic we redirect to it with iptables.

The iptables configuration is fiddly but not complicated.

The important lines are like so:

```
iptables -t nat -N SHADOWSOCKS
iptables -t nat -I PREROUTING -j SHADOWSOCKS
iptables -t nat -A SHADOWSOCKS -p tcp -j REDIRECT --to-ports $ss_local_port
```

The `REDIRECT` target takes incoming traffic and routes it to the local machine. While this does work for transparent proxying, it's not a perfect fit -- it changes the destination IP in the packet and a call to `getsockopt()` is required at a later time to retrieve the original destination. `TPROXY` would be better, but unfortunately it's not available on AsusWRT-Merlin.

So you set up iptables, run ss-redir with the configuration specifying that it binds to 127.0.0.1 as the local address, and you're good to go. Right?

Except it doesn't work. Connecting from a machine on the LAN gives "connection refused". Debugging this with the benefit of hindsight is relatively simple: "connection refused" is the ICMP error returned by the kernel when there's no process listening on the port. So even if there's a small problem with ss-redir's configuration, that wouldn't matter -- it's not even listening on the right port + interface! The problem must be rather basic.

A closer look at `REDIRECT`'s documentation confirms this:

> \[`REDIRECT`] redirects the packet to the machine itself by changing the destination IP to the primary address of the incoming interface (locally-generated packets are mapped to the 127.0.0.1 address).

Aha! Since packets from the LAN arrive on the gateway's IP (usually 192.168.0.1), that is the interface to which they're sent. So we must change `ss-redir` to bind to that interface. Or, more simply, just have it bind to all interfaces 0.0.0.0.

#### ss-rules

There's this cool thing called ss-rules which was designed for OpenWRT but which totally doesn't run at all on AsusWRT-Merlin. Why?

-	It uses getopts instead of getopt (this sounds like a joke, but it's not)
-	It uses a new version of ipset, which AsusWRT-Merlin doesn't have
-	It relies on TPROXY for UDP forwarding, which Merlin doesn't have
-	There's this thing called UCI, which is an OpenWRT-only thing

It's here:

https://github.com//shadowsocks/luci-app-shadowsocks

But it has to be modified heavily. But that's done.

shadowsocks startup can be done in the \``/jffs/scripts/nat-start` script, which according to [this page](https://github.com/RMerl/asuswrt-merlin/wiki/Iptables-tips) is where nat rules should be added to iptables.

To set all this up, just

```bash
opkg install git git-http getopt
mkdir -p /opt/src/github.com/the80scalled
cd /opt/src/github.com/the80scalled
git clone https://github.com/the80scalled/misc.git

tee /jffs/scripts/nat-start <<-EOF
#!/bin/sh
/opt/src/github.com/the80scalled/misc/net/ss start
EOF
chmod +x /jffs/scripts/nat-start
```

#### DNS

DNS is next on the agenda.

The great firewall appears to intercept and tamper with unencrypted DNS requests to some servers, while other servers are blocked entirely. Even if we had [a list of all the Chinese domains](https://github.com/felixonmars/dnsmasq-china-list), it's clear that normal DNS cannot be used from within China.

Instead, there are a few options:

-	Proxy DNS traffic through shadowsocks. This would be ideal, but unfortunately this requires the `TPROXY` module, which AsusWRT-Merlin does not have.
-	Use [dnscrypt](https://github.com/jedisct1/dnscrypt-proxy). This works for a while, but is also unreliable, perhaps because the great firewall sometimes blocks its traffic.
-	Use dnscrypt with the `--tcp-only` option. This works, but is extremely slow -- so slow, in fact, that Chrome often times out before the DNS request returns.
-	Use ChinaDNS. This seems ideal, except the project is old.
-	Use redsocks(2) to tunnel DNS traffic through shadowsocks.

ChinaDNS looks like the most promising option. Here's a quote from a [great explanation](http://dinever.com/2015/04/22/Run-Shadowsocks-on-OpenWRT) of how ChinaDNS works:

> The GFW(Great Firewall of China) has multiple methods to block network. One of them is the DNS spoofing, also named DNS Cache Poisoning. The GFW intercepts all UDP traffic on port 53(traffic on UDP port 53 usually means that it is a DNS lookup) and quickly, ahead of the real DNS server, send a fake response to the user when it finds the domain keyword matches the GFW blacklist. By this way the GFW may block foreign websites by faking the results of DNS queries that was made under it, which means that clients can not get the real IP address of the domain name, so of course they can not reach to the real server.
>
> To get rid of the DNS sppofing we need ChinaDNS, which creates a UDP DNS Server at a certian local port. ChinaDNS has a built-in IP blacklist. When a DNS query was made by the client to the ChinaDNS server, it looks up from the upstream DNS server. If the result matches an entry from the IP blacklist, ChinaDNS would regard it as a fake IP address and would wait for the result from the real DNS server.

ChinaDNS is quite easy to install:

```bash
opkg install chinadns bind-dig

tee /jffs/configs/dnsmasq.conf.add <<-EOF
# Pay no attention to /etc/resolv.conf
no-resolv
server=127.0.0.1#5354
EOF
service restart_dnsmasq
```

Note that we've installed the awesome `dig` tool, which shows the full results of DNS queries like

```
dig @127.0.0.1 www.nytimes.com -p5354
```

Anyway, the chinadns startup configuration isn't quite correct. We need to change the port number, add the `-m` option, and specify an alternate DNS server (it's a good idea to use one that's in the same city as your VPN):

```
sed -i -r '/^ARGS/cARGS="-l /opt/etc/chinadns_iplist.txt -c /opt/src/github.com/the80scalled/misc/net/cnroute.txt -p 5354 -s 114.114.114.114,61.23.13.11,208.67.222.222:443,8.8.8.8 -m"' \
    /opt/etc/init.d/S56chinadns


/opt/etc/init.d/S56chinadns start
```

And it should start.

To test, simply look up some popular domains:

| Domain          | Default (Poisoned) | Correct        |
|-----------------|--------------------|----------------|
| www.nytimes.com | 31.13.90.3         | 173.252.120.68 |
| www.twitter.com | 37.61.54.158       | 159.106.121.75 |

#### cnroute.txt

```
curl 'http://ftp.apnic.net/apnic/stats/apnic/delegated-apnic-latest' | grep ipv4 | grep CN | awk -F\| '{ printf("%s/%d\n", $4, 32-log($5)/log(2)) }' > cnroute.txt
```

#### Selective routing

There are two ways to achieve this:

-	Create virtual SSIDs, where each one is VPN'ed to a different country
-	Magically route different IP ranges to different VPN servers

#### Other things to do

-	Load-balance across multiple VPN servers
-	Ad blocking, perhaps from [here](https://gitlab.com/spitfire-project/ublockr/blob/master/README.md) or perhaps from [here](http://jacobsalmela.com/block-millions-ads-network-wide-with-a-raspberry-pi-hole-2-0/)

### Appendix

##### TomatoUSB and iptables: a tale of woe

And after about a dozen hours of experimentation, I discovered that TomatoUSB's latest build for RT-N66U (August 2016 or so) is riddled with bugs -- including a bug that, under dual WAN, generates improperly formatted iptables configuration every time anything in the network changes. I worked around this by writing a script that ran every few seconds and looked for /etc/iptables.error and, if it was found, fix it with a few `sed` lines and apply it. What a joke.
