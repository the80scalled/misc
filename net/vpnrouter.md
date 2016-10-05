Turning an RT-N66U into an awesome VPN router
=============================================

It takes a long time (less if you have this guide), but it's worth it.

### Firmware

There's no stock firmware out there with support for shadowsocks, so you have to go custom. There are basically five options here:

-	A Chinese-made custom build with shadowsocks and everything already built in. The problem is that they're in Chinese and if something breaks, you'll have to spend time fixing it, which may or may not be possible.
-	OpenWRT. Most of the shadowsocks articles focus around this option. The problem is that OpenWRT is [basically broken](https://dev.openwrt.org/ticket/10852#comment:49) on the RT-N66U, and there are no plans to fix it.
-	Tomato. Here there are a few options, such as Advanced Tomato and TomatoUSB. I tried both and found that the former couldn't keep an internet connection up for more than a few hours, and found the latter to be riddled with bugs.
-	DD-WRT. I didn't try this because the router's page didn't exactly fill me with hope. It seems to have better support than OpenWRT, but worse than Tomato.
-	AsusWRT-Merlin. This is basically the stock firmware with a few features and bug fixes added on. I ruled this out early on because dual WAN seemingly didn't support load balancing with failover...except that it does, and it's far more stable than Tomato Shibby's implementation.

The one drawback with AsusWRT-Merlin is that virtual SSIDs aren't configurable under the GUI, but I'll take scriptable and stable over user-friendly and unstable.

### Getting started with AsusWRT-Merlin

Flash it, set it up, enable SSH, all that jazz.

Most modern routers use a package management system like apt-get, only lighter. Luckily, they're all mostly compatible, so the ecosystem seems to be stabilizing rather nicely. The flavor du jour is called `entware`, and it needs some extra disk space, so we need to get that set up.

First, find the smallest USB thumbdrive you own (a 1GB micro SD card in a tiny USB adapter works the best), wipe it and delete all partitions, then insert it into the router in the *top slot* (this ensures it doesn't get renamed later). We're going to create a Linux filesystem on it:

1.	`fdisk -l` Lists all physical disks. You should see /dev/sda.
2.	`fdisk /dev/sda`
3.	`p` to print the partition table. Shouldn't have anything on it. If there is, use the commands to delete it.
4.	`n` to create a new partition; select `p`, primary partition; `1` for index = 1.
5.	Select the default start and stop cylinders.
6.	`p` to see your beautiful work. (it's not saved yet!) The partition name should be `/dev/sdb1`.
7.	`w` to write the partition table to disk.
8.	`q` to exit.

So now there's a partition on the drive, but it's empty. Like, all zeros empty. We need to fix that. It's already mounted (in use), so to make big changes to it you have to unmount it first before creating the filesystem and mounting it:

```bash
umount /dev/sda1
mkfs.ext3 /dev/sda1
mkdir /mnt/usb
mount /dev/sda1 /mnt/usb
```

And finally, as detailed on [this page](https://github.com/RMerl/asuswrt-merlin/wiki/Entware), no need to be a hero, just use the setup script, which is already in the ROM and part of the $PATH:

```bash
entware-setup.sh
```

And select partition `1`, of course. Congratulations, you now have a persistent /opt folder with entware installed.

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

The `REDIRECT` target takes incoming traffic and routes it to the local machine. Lots of pages online talk about how this is great for transparent proxying, or proxying traffic from machines on the intranet without them caring that the proxy is happening. This is exactly what we're trying to do, so it's a perfect fit.

So you set up iptables, run ss-redir with the configuration specifying that it binds to 127.0.0.1 as the local address, and you're good to go.

Except it doesn't work. Connecting from a machine on the LAN gives "connection refused". Debugging this with the benefit of hindsight is relatively simple: "connection refused" is the ICMP error returned by the kernel when there's no process listening on the port. So even if there's a small problem with ss-redir's configuration, that wouldn't matter -- it's not even listening on the right port + interface! The problem must be rather basic.

A closer look at `REDIRECT`'s documentation confirms this:

> \[`REDIRECT`] redirects the packet to the machine itself by changing the destination IP to the primary address of the incoming interface (locally-generated packets are mapped to the 127.0.0.1 address).

Aha! Since packets from the LAN arrive on the gateway's IP (usually 192.168.0.1), that is the interface to which they're sent. So we must change `ss-redir` to bind to that interface. Or, more simply, just have it bind to all interfaces 0.0.0.0.

#### ss-rules

There's this cool thing called ss-rules which was designed for OpenWRT but which totally doesn't run at all on OpenWRT. It's because it uses getopts instead of getopt, and the ipset version is different too.

It's here:

https://github.com//shadowsocks/luci-app-shadowsocks

But it has to be modified heavily. But that's done.

#### DNS

DNS is next on the agenda. Apparently ChinaDNS isn't so well-maintained anymore, so there's this felixonmars guy on github.com who seems to be doing a good job.

Install git:

```
opkg install git
opkg install git-http
```

And clone the repository:

```
mkdir -p /mnt/usb/src/github.com/felixonmars
cd /mnt/usb/src/github.com/felixonmars
git clone https://github.com/felixonmars/dnsmasq-china-list.git
```

Meanwhile, get DNSCrypt set up from [here](https://github.com/RMerl/asuswrt-merlin/wiki/Secure-DNS-queries-using-DNSCrypt).

To test, simply look up some popular domains:

| Domain          | Default (Poisoned) | Correct        |
|-----------------|--------------------|----------------|
| www.nytimes.com | 31.13.90.3         | 173.252.120.68 |
| www.twitter.com | 37.61.54.158       | 159.106.121.75 |

### Appendix

##### TomatoUSB and iptables: a tale of woe

And after about a dozen hours of experimentation, I discovered that TomatoUSB's latest build for RT-N66U (August 2016 or so) is riddled with bugs -- including a bug that, under dual WAN, generates improperly formatted iptables configuration every time anything in the network changes. I worked around this by writing a script that ran every few seconds and looked for /etc/iptables.error and, if it was found, fix it with a few `sed` lines and apply it. What a joke.
