VPN router with iptables and stuff
==================================

A month ago I was given the task of setting up a router with VPN (shadowsocks), countermeasures against DNS poisoning, and the ability to fail-over the main PPPoE connection to a 4G modem. These are all cool features but it turns out that getting them to all play together is complicated. In all, it probably took about 30-40 hours.

At the heart of the complexity is the wonderful program iptables, which is the interface to Network Manager. There's precious little information online that actually explains in detail how a non-trivial iptables setup works, so I had to piece it together through reading dozens of articles and FAQs and through a good deal of trial and error.

### Tables and chains

Articles love to talk about tables and chains, but the reality is that these are both one-dimensional ways of looking at the actual two-dimensional filtering process that happens inside iptables.

So let's look at an actual meaty example and figure out what every little thing means. Here's the output of `iptables-save` on my TomatoUSB router connected to a PPPoE gateway as 123.119.82.246 (nope, not my real IP) and with LAN subnet 192.168.0.0/22:

```
# Generated by iptables-save v1.3.8 on Sat Oct  1 10:47:35 2016
*nat
:PREROUTING ACCEPT [2168:237113]
:POSTROUTING ACCEPT [557:36441]
:OUTPUT ACCEPT [2020:106023]
:WANPREROUTING - [0:0]
-A PREROUTING -d 123.119.82.246 -j WANPREROUTING
-A PREROUTING -d 192.168.0.0/255.255.252.0 -i ppp0 -j DROP
-A POSTROUTING -o ppp0 -j MASQUERADE
-A POSTROUTING -s 192.168.0.0/255.255.252.0 -d 192.168.0.0/255.255.252.0 \
    -o br0 -j SNAT --to-source 192.168.0.1
-A WANPREROUTING -p icmp -j DNAT --to-destination 192.168.0.1
COMMIT
# Completed on Sat Oct  1 10:47:35 2016
# Generated by iptables-save v1.3.8 on Sat Oct  1 10:47:35 2016
*mangle
:PREROUTING ACCEPT [81044:60735130]
:INPUT ACCEPT [3746:332300]
:FORWARD ACCEPT [76994:60336621]
:OUTPUT ACCEPT [3461:465518]
:POSTROUTING ACCEPT [80464:60804926]
-A PREROUTING -i ppp0 -j DSCP --set-dscp 0x00
-A FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
COMMIT
# Completed on Sat Oct  1 10:47:35 2016
# Generated by iptables-save v1.3.8 on Sat Oct  1 10:47:35 2016
*filter
:INPUT DROP [169:8933]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [3462:466582]
:shlimit - [0:0]
:wanin - [0:0]
:wanout - [0:0]
-A INPUT -m state --state INVALID -j DROP
-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A INPUT -p tcp -m tcp --dport 22 -m state --state NEW -j shlimit
-A INPUT -i lo -j ACCEPT
-A INPUT -i br0 -j ACCEPT
-A FORWARD -m account --aaddr 192.168.0.0/255.255.252.0 --aname lan
-A FORWARD -i br0 -o br0 -j ACCEPT
-A FORWARD -m state --state INVALID -j DROP
-A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
-A FORWARD -i ppp0 -j wanin
-A FORWARD -o ppp0 -j wanout
-A FORWARD -i br0 -j ACCEPT
-A shlimit -m recent --set --name shlimit --rsource
-A shlimit -m recent --update --seconds 60 --hitcount 4 --name shlimit --rsource -j DROP
COMMIT
# Completed on Sat Oct  1 10:47:35 2016
```

Nice and neat. Organized according to table and then chain. Completely concise and correct. And completely unintelligible for a n00b like me. What I want to know are things like, How do packets that my computer sends to external IP addresses get to where they need to go, and how do they get back? How do all the packets know exactly where to go?

All in good time, all in good time.

I mentioned that the above is a one-dimensional view of a two-dimensional process. Here is that process in all its glory:

![the amazing iptables flowchart of awesomeness](http://inai.de/images/nf-packet-flow.png) Credit: j.eng, http://inai.de/

I know this looks complicated, but trust me, you'll thank me later for not oversimplifying this. In fact, at a glance you can already see some familiar terms: mangle, PREROUTING, nat, INPUT. It's not that bad.

Each square box is a pair of table + chain. Rounded boxes are either itpables modules (like conntrack) or other processes that control the routing of packets or something (like routing decision). Also, ignore the blue link layer, since everything that we're interested in happens in the network layer or above, and all the other simpler diagrams (like [this one](http://www.adminsehow.com/wp-content/uploads/2011/09/packet_flow9.png)) appear to ignore it too.

What we're looking at is a map of the way that all packets traverse the networking system in the kernel. At left they're received by an interface, at top (around "local process") they're either delivered to a running program or emitted from one, and at right they're delivered to another interface.

This is our yellow brick road, our Rosetta Stone.

Here's another way of looking at more or less the same thing:

![another view](http://www.linuxjournal.com/files/linuxjournal.com/ufiles/imagecache/large-550px-centered/u1002061/10822f1.png)

### iptables rules take 2: in order of execution

Now we can reproject the `iptables-save` output into something much more meaningful.

#### Ingress rules

When a packet arrives on any interface, the following rules are executed. Let's call these the "ingress rules" (no relation to anything else called ingress in this domain):

```
*mangle :PREROUTING ACCEPT [81044:60735130]
*mangle -A PREROUTING -i ppp0 -j DSCP --set-dscp 0x00

*nat    :PREROUTING ACCEPT [2168:237113]
*nat    -A PREROUTING -d 123.119.82.246 -j WANPREROUTING
*nat    -A PREROUTING -d 192.168.0.0/255.255.252.0 -i ppp0 -j DROP
*nat    -A PREROUTING -d 192.168.0.0/255.255.252.0 -i vlan3 -j DROP

*nat    :WANPREROUTING - [0:0]
*nat    -A WANPREROUTING -p icmp -j DNAT --to-destination 192.168.0.1
```

We'll look at these in more detail later.

But first, let's a digression to talk about how these rules work. Basically, each rule is applied to the packet, one after another. Each rule has two parts: a set of match conditions and, if the match succeeds, either a set of actions to take on the packet (such as modifying the packet in some way) and/or a target to jump (`-j`) to. There are some special chains:

-	`DROP` sends the packet to `/dev/null` and quits.
-	`REJECT` sends the packet to `/dev/null` and responds to the source IP with an ICMP "connection refused" packet.
-	`ACCEPT` skips all further rules *in the current chain* as well as *in the current table* (but other tables/chains will still get a crack at it) (more info [here](https://www.frozentux.net/iptables-tutorial/chunkyhtml/c3965.html)\).
-	`LOG` logs the packet and then continues processing.

Here we see some user-defined chains, such as `WANPREROUTING`, so jumping (`-j`) to that chain does what you think: it executes the rules in that chain and then returns. User-defined chains are a good way to encapsulate a set of related rules, just like subroutines in normal code.

Ok, end of digression. Anyway, after the above rules are applied, all the diagrams I've seen say that Network Manager makes a "Routing Decision". None of the diagrams explain what that means, so take a look at [this StackExchange answer](http://unix.stackexchange.com/questions/193669/on-a-router-what-decides-if-a-packet-should-be-forwarded-or-directed-into-the-r?rq=1).

Basically, if the destination IP of the packet is the IP address of any of the system's interfaces (remember, in this case the "system" is the router), then the packet is routed "up" in the above diagram, and it is eventually either delivered to a running process, or rejected (as in `-j REJECT`) if nobody's listening on that port + protocol.

So, if that's the case, here's the set of rules that come up next:

#### Deliver-to-process rules

```
*mangle :INPUT ACCEPT [3746:332300]
*filter :INPUT DROP [169:8933]
*filter :shlimit - [0:0]
*filter -A INPUT -m state --state INVALID -j DROP
*filter -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
*filter -A INPUT -p tcp -m tcp --dport 22 -m state --state NEW -j shlimit
*filter -A INPUT -i lo -j ACCEPT
*filter -A INPUT -i br0 -j ACCEPT
*filter -A shlimit -m recent --set --name shlimit --rsource
*filter -A shlimit -m recent --update --seconds 60 --hitcount 4 --name shlimit \
    --rsource -j DROP
```

After these rules are run on the packet, the kernel checks if the packet is deliverable to any currently running process (think `netstat -an`). If so, it delivers it. Otherwise, it `-j REJECT`s it.

#### Accept-from-process rules

Whenever a process sends a packet, these rules are run on the packet:

```
*mangle :OUTPUT ACCEPT [3461:465518]
*nat    :OUTPUT ACCEPT [2020:106023]
*filter :OUTPUT ACCEPT [3462:466582]
```

Nothing to see here. Not surprising because we trust the software running on the router.

#### Forwarding rules

Ok, back to the Routing Decision. If the packet's destination IP is *not* on one of the system's interfaces, these rules are run:

```
*mangle :FORWARD ACCEPT [76994:60336621]
*mangle -A FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
*filter :FORWARD DROP [0:0]
*filter :wanin - [0:0]
*filter :wanout - [0:0]
*filter -A FORWARD -m account --aaddr 192.168.0.0/255.255.252.0 --aname lan
*filter -A FORWARD -i br0 -o br0 -j ACCEPT
*filter -A FORWARD -m state --state INVALID -j DROP
*filter -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
*filter -A FORWARD -i ppp0 -j wanin
*filter -A FORWARD -o ppp0 -j wanout
*filter -A FORWARD -i vlan3 -j wanin
*filter -A FORWARD -o vlan3 -j wanout
*filter -A FORWARD -i br0 -j ACCEPT
```

This is the essence of being a router: forwarding packets from an intranet to the internet, as well as between machines on the intranet.

#### Egress rules

Once the packet -- any packet -- is destined for another machine on the network and is about to leave, these rules are run:

```
*mangle :POSTROUTING ACCEPT [80464:60804926]
*nat    :POSTROUTING ACCEPT [557:36441]
*nat    -A POSTROUTING -o ppp0 -j MASQUERADE
*nat    -A POSTROUTING -o vlan3 -j MASQUERADE
*nat    -A POSTROUTING -s 192.168.0.0/255.255.252.0 -d 192.168.0.0/255.255.252.0 \
     -o br0 -j SNAT --to-source 192.168.0.1
```

If you put these all together, the flowchart looks like this:

```

     (NETWORK)
         |
         V
------Ingress -----
|                 |
|                 V
|        Deliver-to-process
|                 |
V             (PROCESS)
Forward           |
|         Accept-from-process
|                 |
---------|---------
         V
      Egress
         |
      (NETWORK)
```

Not so bad.

Now that we have this new perspective, we can see that the concepts of tables actually does make a lot of sense:

-	`*mangle` tends to be used for rules that change packets in order to, say, solve compatibility problems between networks.
-	`*nat` tends to be used for, well, NAT: changing source and destination IPs so that, for example, when you open up Chrome and go to google.com, Google's server's don't try to send the response to 192.168.1.100. *nat is often used with the `PREROUTING` and `POSTROUTING` chains.
-	`*filter` tends to be used to allow/disallow packets. This is the firewall. Most rules in the *filter table tend to be in the `INPUT` and `FORWARD` chains.

Of course, all of the above are just conventions; there's nothing preventing you from adding a rule to drop incoming SSH connections in the `*mangle` table. But don't do that.

### The interpreter of rules

Now let's see what all these rules actually do. Let's start with the `*mangle` table because these rules are self-contained:

`
-A FORWARD -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
`

This is an important rule which trims the maximum segment size (MSS) for TCP SYN and RST SYN packets, which solves hard-to-diagnose problems with certain internet connections. For more detail, check [here](http://lartc.org/howto/lartc.cookbook.mtu-mss.html) and [here](http://www.tldp.org/HOWTO/Adv-Routing-HOWTO/lartc.cookbook.mtu-mss.html). There is [some debate](http://www.snbforums.com/threads/iptables-clamp-mss-to-pmtu.23873/) about whether it should be in the `mangle` or `nat` tables, but most seem to have concluded that the `mangle` table, in the `FORWARD` chain, is the best place.

`
-A PREROUTING -i ppp0 -j DSCP --set-dscp 0x00
`

DSCP modifies the Differentiated Services Field inside a TCP packet. The Differentiated Services Field can be used to do a kind of QoS, for example to make sure that an interactive SSH session gets priority over other heavy traffic like streaming a movie. Apparently the authors of the firmware decided that all differentiated services field values coming from the outside (ppp0 is the WAN interface) are bogus and should be cleared.

#### nat table

Here's where we start getting to the meat.

```
-A PREROUTING -d 123.119.82.246 -j WANPREROUTING
-A WANPREROUTING -p icmp -j DNAT --to-destination 192.168.0.1
```

TomatoUSB, the firmware I'm running, has defined a new chain called WANPREROUTING. All traffic destined for the router's external IP (123.119.82.246) gets run through that chain.

The one rule in the WANPREROUTING chain takes all icmp packets (like for `ping`) and redirects them to 192.168.0.1, the router's local IP, while leaving the source IP unchanged. I can't figure out why they'd want to do this, unless there's something about the ppp0 interface that doesn't like dealing with pings.

[Here's](https://www.frozentux.net/iptables-tutorial/chunkyhtml/x4033.html) more info on the DNAT target. It's only available in PREROUTING and OUTPUT chains, which is likely a constraint to enforce best practices around the use of DNAT.

```
-A PREROUTING -d 192.168.0.0/255.255.252.0 -i ppp0 -j DROP
```

This takes any traffic on the ppp0 interface (the WAN interface) that's destined for the *internal* subnet, and drops it. This seems strange; if the internet is working properly, then nothing destined for 192.168.0.0/16 should ever get very far on the public internet. But if your ISP is malicious, then yes, if this rule wasn't here then they could get stuff to machines on the local LAN.

```
-A POSTROUTING -o ppp0 -j MASQUERADE
```

When you see MASQUERADE, think "[SNAT](https://www.frozentux.net/iptables-tutorial/chunkyhtml/x4679.html)", which is used to rewrite the source IP on a packet leaving a local network -- for example, when a machine inside the LAN sends a request from source = 192.168.1.100, but you want the response to get back to the router instead.

There's a problem with using SNAT, though: our router's public IP changes all the time, because it's dynamically assigned from the ISP. So we instead use MASQUERADE, which basically looks up the IP of the interface to which the packet has been routed, and uses that source IP. (the `-o ppp0` just means this rule only applies to packets routed to `ppp0`; it's not a hint to MASQUERADE or anything. In fact, at the time the above rule is run, the networking system *has already decided* to route this packet to `ppp0` anyway)

Note that the iptables contain no DNAT rules, so machines inside the local network are totally unreachable by new connections established from the outside.

#### filter table

Ok, this one's a doozy. Here we go:

```
:INPUT DROP [169:8933]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [3462:466582]
```

By default, we're dropping all incoming and forwarded traffic. Secure by default. Good.

```
-A INPUT -i lo -j ACCEPT
-A INPUT -i br0 -j ACCEPT
```

Remember, INPUT here refers to traffic that's destined for the router itself. So the first rule accepts any traffic that's coming *from* the router *to* the router. That sounds silly, until you SSH into the router and can't `ping google.com` because ping can't talk to your local DNS server (probably dnsmasq) which is running on -- oh right -- the router.

The second rule accepts all traffic coming from the LAN, which is the device `br0`.

```
-A FORWARD -i br0 -j ACCEPT
```

Oh, and also allow all outgoing traffic from machines on the LAN. Seems safe enough.

```
-A FORWARD -i br0 -o br0 -j ACCEPT
```

This one is interesting. From the LAN to the LAN, what can that mean? Why don't the machines talk to themselves? Oh right, they can't. That's why we have a router, so my iPhone can talk to the Apple TV.

In other words, if we remove this rule, then machines on the local network wouldn't be able to talk to each other. That would be useful if you're running a coffee shop or an airport lounge.

```
-A INPUT -m state --state INVALID -j DROP
-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A FORWARD -m state --state INVALID -j DROP
-A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT

```

Here's a set of four very standard rules, applied both to connections that terminate at the router, as well as to connections forwarded *through* the router in both directions.

`-m state` means we're asking the `state` module to take a look at this packet. The `state` module tracks the state of connections that pass through this system. This allows you to define different behavior for packets, depending on if they're a totally new connection, or if they're part of an established connection.

The last rule in the set above is therefore one of the most important rules in the entire set. Why? When a machine on the local network requests, say, a web page from an external web server, the web server's response must then be forwarded back to the machine that requested it. But hold on, by default we're `DROP`ing all forwarded packets:

```
:FORWARD DROP [0:0]
```

Great, so now nobody can browse the internet. But we also can't just FORWARD everything by default. So how do we forward the server's response, while also blocking hackers who want to get at the machines on the local network? The answer is the `state` module.

Basically, when a user first tries to connect to a server running on this system, the connection state is NEW; when the server sends the response back, the connection state is ESTABLISHED. You see RELATED when, for example, you try connecting to a remote machine and you get an ICMP packet back saying that the connection was refused -- that ICMP packet is in state RELATED.

[Here's](http://www.iptables.info/en/connection-state.html) an awesome in-depth look at the conntrack module. This page, in table 7-1, is also where we see the recommendation to drop packets in the INVALID state.

By the way, the `state` module has been deprecated in favor of the `conntrack` module -- see [this StackExchange answer](http://unix.stackexchange.com/questions/108169/what-is-the-difference-between-m-conntrack-ctstate-and-m-state-state) for more info.

```
-A FORWARD -i ppp0 -j wanin
-A FORWARD -o ppp0 -j wanout
```

These might be useful later, but right now the wanin and wanout chains are empty, so they don't do anything.

```
-A FORWARD -m account --aaddr 192.168.0.0/255.255.252.0 --aname lan
```

Hmm, we know that `account` must be a module, but what does it do? It [monitors network traffic](http://www.intra2net.com/en/developer/ipt_ACCOUNT/index.php). This must be what powers the bandwidth monitors in the TomatoUSB UI.

```
-A INPUT -p tcp -m tcp --dport 22 -m state --state NEW -j shlimit
-A shlimit -m recent --set --name shlimit --rsource
-A shlimit -m recent --update --seconds 60 --hitcount 4 --name shlimit --rsource -j DROP
```

Finally, we're at the last rules. The first line takes all NEW (remember `-m state`) connections on port 22 -- SSH -- and sends them to the shlimit chain. This chain as presented here is a sort of subroutine that can be used to rate-limit anything -- in this case, SSH connections.

The second line, with `--set`, adds a new entry to the list called `shlimit`, while saving its source IP and port (`--rsource`). The second line looks back at the list (`--update`) and sees if there are 4 matches within the last 60 seconds. If so, the match returns true and the packet is sent to `DROP`.

[This page](https://www.frozentux.net/iptables-tutorial/chunkyhtml/x2702.html#RECENTMATCH) provides a detailed description of the `recent` module.

WARNING: the above page actually recommends not using this to rate-limit connections, since it doesn't handle all corner cases. Apparently something like fail2ban is a better choice.

### Conclusion

Understanding the set of iptables rules used in the router is not the same as understanding how the router functions in its entirety, but it's a good portion of it.