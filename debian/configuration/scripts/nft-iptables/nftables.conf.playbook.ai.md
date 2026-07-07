# nftables Host Firewall Playbook

This playbook describes how to maintain a simple host firewall based on `nftables`.

Scope:

- Debian / Linux host
- native `nftables`
- compatible with Docker, libvirt and `iptables-nft`
- protects the host `INPUT` and `OUTPUT` paths
- does **not** manage Docker/libvirt forwarding or NAT

Important assumptions:

- your own firewall table is `inet hostfw`
- you do **not** use `flush ruleset`
- you do **not** create `table ip filter`
- you do **not** create `table ip nat`
- you do **not** manage the `FORWARD` hook here

---

## 1. Recommended base config

File:

```bash
/etc/nftables.conf
```

Content:

```nft
#!/usr/sbin/nft -f

# Host firewall compatible with nftables + iptables-nft + Docker + libvirt
#
# IMPORTANT:
# - no flush ruleset
# - no table ip filter
# - no table ip nat
# - no FORWARD hook
# - Docker/libvirt/iptables-nft may manage their own tables/chains

# Idempotent reload of only our own table.
# This does not touch Docker/libvirt rules.
destroy table inet hostfw

table inet hostfw {

    chain input {
        type filter hook input priority filter; policy drop;

        # localhost
        iifname "lo" counter accept

        # conntrack hygiene
        ct state invalid counter drop
        ct state established,related counter accept

        # Drop IPv6 on host input
        meta nfproto ipv6 counter drop

        # Put allowed incoming IPv4 services HERE, before the log/drop rule.
        # Example:
        # ip saddr 192.168.50.0/24 tcp dport 22 ct state new counter accept

        # Log and drop new incoming IPv4 traffic to the host
        meta nfproto ipv4 ct state new limit rate 10/minute burst 20 packets \
            log prefix "NFT INPUT NEW DROP: " flags all counter drop

        # Final drop
        counter drop
    }

    chain output {
        type filter hook output priority filter; policy drop;

        # localhost
        oifname "lo" counter accept

        # conntrack hygiene
        ct state invalid counter drop
        ct state established,related counter accept

        # Drop IPv6 on host output
        meta nfproto ipv6 counter drop

        # Allow new outgoing IPv4 connections from host
        meta nfproto ipv4 ct state new counter accept

        # Final drop
        counter drop
    }
}
```

---

## 2. Golden rule for opening an input port

Add allow rules in the `input` chain **before** this rule:

```nft
meta nfproto ipv4 ct state new limit rate 10/minute burst 20 packets \
    log prefix "NFT INPUT NEW DROP: " flags all counter drop
```

Reason: nftables evaluates rules top-down. If your allow rule is below the log/drop rule, it will never be reached.

---

## 3. Open SSH from LAN only

Recommended rule:

```nft
ip saddr 192.168.50.0/24 tcp dport 22 ct state new counter accept
```

Place it here:

```nft
        # Drop IPv6 on host input
        meta nfproto ipv6 counter drop

        # Allow SSH from LAN
        ip saddr 192.168.50.0/24 tcp dport 22 ct state new counter accept

        # Log and drop new incoming IPv4 traffic to the host
        meta nfproto ipv4 ct state new limit rate 10/minute burst 20 packets \
            log prefix "NFT INPUT NEW DROP: " flags all counter drop
```

Do **not** open SSH to the whole world unless you really need it.

Bad idea:

```nft
 tcp dport 22 ct state new counter accept
```

Better:

```nft
ip saddr 192.168.50.0/24 tcp dport 22 ct state new counter accept
```

---

## 4. Open HTTP / HTTPS from LAN

```nft
ip saddr 192.168.50.0/24 tcp dport { 80, 443 } ct state new counter accept
```

Open HTTP / HTTPS from anywhere:

```nft
tcp dport { 80, 443 } ct state new counter accept
```

Use the second version only if the host is meant to expose a public web service.

---

## 5. Allow ping to host

ICMP echo request is not TCP/UDP and does not use `dport`.

Allow ping from LAN:

```nft
ip saddr 192.168.50.0/24 ip protocol icmp icmp type echo-request counter accept
```

Allow ping from anywhere:

```nft
ip protocol icmp icmp type echo-request counter accept
```

Recommended for a workstation/server in LAN:

```nft
ip saddr 192.168.50.0/24 ip protocol icmp icmp type echo-request counter accept
```

---

## 6. Open DNS to the host

Only needed if this machine runs a DNS server.

DNS from LAN:

```nft
ip saddr 192.168.50.0/24 udp dport 53 ct state new counter accept
ip saddr 192.168.50.0/24 tcp dport 53 ct state new counter accept
```

UDP is the normal path. TCP is needed for large replies, zone transfers, DNSSEC cases, etc.

Do not expose DNS publicly unless you know exactly why. Open public recursive DNS is a bad idea.

---

## 7. Open a custom TCP port

Example: allow TCP port `8080` from LAN:

```nft
ip saddr 192.168.50.0/24 tcp dport 8080 ct state new counter accept
```

From one specific IP only:

```nft
ip saddr 192.168.50.10 tcp dport 8080 ct state new counter accept
```

From anywhere:

```nft
tcp dport 8080 ct state new counter accept
```

KISS recommendation: prefer source restriction whenever possible.

---

## 8. Open a custom UDP port

Example: allow UDP port `51820` for WireGuard:

```nft
udp dport 51820 ct state new counter accept
```

With source restriction:

```nft
ip saddr 192.168.50.0/24 udp dport 51820 ct state new counter accept
```

For public VPN entrypoints, source restriction may not be possible.

---

## 9. Safe reload procedure

Before applying changes:

```bash
sudo nft -c -f /etc/nftables.conf
```

If syntax is OK, apply:

```bash
sudo systemctl reload nftables
```

or:

```bash
sudo nft -f /etc/nftables.conf
```

Recommended when working over SSH:

1. Open a second root shell.
2. Schedule temporary rollback:

```bash
sudo sh -c 'sleep 60; nft flush table inet hostfw' &
```

3. Reload firewall:

```bash
sudo nft -c -f /etc/nftables.conf && sudo nft -f /etc/nftables.conf
```

4. Test that SSH still works.
5. Kill the rollback job if everything is OK:

```bash
jobs
sudo pkill -f 'sleep 60; nft flush table inet hostfw'
```

Warning: `nft flush table inet hostfw` removes rules from your own table only. It does not remove the table itself and does not touch Docker/libvirt tables.

---

## 10. Read drop logs

Live kernel log:

```bash
sudo journalctl -k -f
```

Filter only nftables input drops:

```bash
sudo journalctl -k -g "NFT INPUT NEW DROP"
```

Follow only matching entries:

```bash
sudo journalctl -k -f -g "NFT INPUT NEW DROP"
```

Using `dmesg`:

```bash
sudo dmesg -w
```

If `rsyslog` writes kernel logs to files:

```bash
sudo grep "NFT INPUT NEW DROP" /var/log/kern.log
```

or:

```bash
sudo grep "NFT INPUT NEW DROP" /var/log/syslog
```

---

## 11. Example log interpretation

Example log line may contain fields like:

```text
NFT INPUT NEW DROP: IN=enp3s0 OUT= MAC=... SRC=192.168.50.20 DST=192.168.50.149 PROTO=TCP SPT=51344 DPT=22
```

Meaning:

- `IN=enp3s0` - packet entered via interface `enp3s0`
- `SRC=192.168.50.20` - source IP
- `DST=192.168.50.149` - destination IP, your host
- `PROTO=TCP` - protocol
- `SPT=51344` - source port
- `DPT=22` - destination port

If you see repeated drops to `DPT=22`, something is trying to connect to SSH.

If you see repeated drops to random ports, it is probably scanning or service discovery noise.

---

## 12. Check loaded ruleset

Full ruleset:

```bash
sudo nft list ruleset
```

Only your table:

```bash
sudo nft list table inet hostfw
```

Only input chain:

```bash
sudo nft list chain inet hostfw input
```

With handles:

```bash
sudo nft -a list chain inet hostfw input
```

With counters:

```bash
sudo nft list chain inet hostfw input
```

Counters are useful to confirm which rule is being hit.

---

## 13. Reset counters

Reset counters in your table:

```bash
sudo nft reset counters table inet hostfw
```

Then generate traffic and check again:

```bash
sudo nft list chain inet hostfw input
```

---

## 14. Test from another machine

Ping:

```bash
ping HOST_IP
```

TCP port test:

```bash
nc -vz HOST_IP 22
nc -vz HOST_IP 80
nc -vz HOST_IP 443
```

UDP is harder to test with `nc`, but you can still try:

```bash
nc -vzu HOST_IP 51820
```

For real validation, use tcpdump on the host.

---

## 15. tcpdump diagnostics

Watch incoming SSH attempts:

```bash
sudo tcpdump -ni any 'tcp port 22'
```

Watch ICMP:

```bash
sudo tcpdump -ni any icmp
```

Watch one source IP:

```bash
sudo tcpdump -ni any host 192.168.50.20
```

Watch one destination port:

```bash
sudo tcpdump -ni any 'tcp dst port 8080'
```

If tcpdump sees packets but nftables counters do not move, you are probably looking at the wrong hook, wrong family, wrong interface, or traffic path.

---

## 16. conntrack diagnostics

List current conntrack entries:

```bash
sudo conntrack -L
```

Watch live conntrack events:

```bash
sudo conntrack -E
```

Useful filters:

```bash
sudo conntrack -L -p tcp
sudo conntrack -L -p udp
sudo conntrack -L | grep 192.168.50.20
```

Remember: the first packet of a connection is usually `ct state new`. Replies are usually `established`.

---

## 17. Common mistakes

### Mistake: placing allow rules after drop

Bad:

```nft
meta nfproto ipv4 ct state new log prefix "NFT INPUT NEW DROP: " counter drop
ip saddr 192.168.50.0/24 tcp dport 22 ct state new counter accept
```

The SSH rule will never be reached.

Correct:

```nft
ip saddr 192.168.50.0/24 tcp dport 22 ct state new counter accept
meta nfproto ipv4 ct state new log prefix "NFT INPUT NEW DROP: " counter drop
```

---

### Mistake: using `flush ruleset`

Do not use:

```nft
flush ruleset
```

It wipes all nftables state, including Docker/libvirt/iptables-nft generated rules.

Use:

```nft
destroy table inet hostfw
```

This reloads only your own table.

---

### Mistake: creating `table ip filter`

Avoid:

```nft
table ip filter { ... }
```

Docker/libvirt/iptables-nft may use the same table name/family. You can create conflicts such as:

```text
table `filter' is incompatible, use 'nft' tool
```

Use your own table name instead:

```nft
table inet hostfw { ... }
```

---

### Mistake: managing FORWARD here

If Docker/libvirt manage forwarding, do not create your own `FORWARD` policy here unless you intentionally want to own forwarding.

For this host firewall, keep it simple:

- manage `input`
- manage `output`
- leave forwarding/NAT to Docker/libvirt

---

## 18. Minimal template for adding a new service

Add this before the log/drop rule:

```nft
# Allow SERVICE_NAME from SOURCE
ip saddr SOURCE_CIDR tcp dport PORT ct state new counter accept
```

Example:

```nft
# Allow app on TCP/8080 from LAN
ip saddr 192.168.50.0/24 tcp dport 8080 ct state new counter accept
```

Then validate:

```bash
sudo nft -c -f /etc/nftables.conf
```

Apply:

```bash
sudo nft -f /etc/nftables.conf
```

Verify:

```bash
sudo nft list chain inet hostfw input
sudo journalctl -k -g "NFT INPUT NEW DROP"
```

---

## 19. Operational checklist

Before change:

```bash
sudo nft list ruleset > /root/nft.ruleset.backup.$(date +%F_%H%M%S).nft
sudo nft -c -f /etc/nftables.conf
```

Apply:

```bash
sudo nft -f /etc/nftables.conf
```

Verify:

```bash
sudo nft list table inet hostfw
sudo nft list chain inet hostfw input
sudo journalctl -k -g "NFT INPUT NEW DROP"
```

Test from another host:

```bash
nc -vz HOST_IP PORT
```

If broken:

```bash
sudo nft flush table inet hostfw
```

Then fix `/etc/nftables.conf` and reload again.

---

## 20. KISS recommendation

Default stance:

- deny incoming traffic to host
- allow only explicit required ports
- restrict source IP/subnet whenever possible
- log new input drops with rate limit
- do not touch Docker/libvirt tables
- do not use `flush ruleset`
- do not manage forwarding unless you really need to
