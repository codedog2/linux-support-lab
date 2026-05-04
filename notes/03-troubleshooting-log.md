# Troubleshooting log

Six independent issues hit while assembling the lab on a WSL2 Ubuntu 24.04
host with k3s and Pi-hole, recorded at the time. Each entry: symptom →
investigation → root cause → fix → lesson.

The most valuable artifact in this repo. Skim this file first.

---

## Issue 1 — Default WSL distribution was version 1, not 2

**When**: 2026-05-04, before Docker install.

### Symptom

`docker info` not yet possible because Docker wasn't installed, but a
preflight check showed:

```
> wsl --list --verbose
  NAME      STATE      VERSION
* Ubuntu    Stopped    1
```

### Why it matters

WSL1 is a syscall translation layer that runs Linux binaries against the
Windows kernel. There is no real Linux kernel — therefore no `cgroups`,
no namespaces, no `containerd`, no Docker, no k3s. Continuing to install
Docker on a WSL1 distribution will fail at runtime in confusing ways.

### Fix

```powershell
wsl --set-default-version 2
wsl --set-version Ubuntu 2     # converts the existing rootfs to a VHD
```

Conversion of an existing rootfs takes 3–5 minutes for ~3 GB.

### Verification

```
> wsl -d Ubuntu -- uname -a
Linux DESKTOP-2K1NEHL 6.6.87.2-microsoft-standard-WSL2 #1 SMP PREEMPT_DYNAMIC ...
```

The presence of `microsoft-standard-WSL2` in `uname -r` confirms a real
Linux kernel.

### Lesson

Always run `wsl -l -v` before assuming a Linux WSL host has Docker
prerequisites. Default version on this Windows install was 1, despite WSL
2.6 being available — this is a per-account default and not migrated
automatically.

---

## Issue 2 — systemd-resolved holding 127.0.0.53:53

**When**: After Docker install, on first `docker compose up -d` for Pi-hole.

### Symptom

```
> docker compose up -d
Error response from daemon: failed to set up container networking:
  driver failed programming external connectivity on endpoint pihole:
  failed to bind host port 0.0.0.0:53/tcp: address already in use
```

### Investigation

```
$ ss -tulnp | grep ':53\b'
udp UNCONN 0 0  127.0.0.54:53     0.0.0.0:*  users:(("systemd-resolve",pid=114,fd=16))
udp UNCONN 0 0  127.0.0.53%lo:53  0.0.0.0:*  users:(("systemd-resolve",pid=114,fd=14))
udp UNCONN 0 0  10.255.255.254:53 0.0.0.0:*
tcp LISTEN 0 4096  127.0.0.53%lo:53  0.0.0.0:*  users:(("systemd-resolve",pid=114,fd=15))
tcp LISTEN 0 4096  127.0.0.54:53     0.0.0.0:*  users:(("systemd-resolve",pid=114,fd=17))
tcp LISTEN 0 1000  10.255.255.254:53 0.0.0.0:*
```

`systemd-resolve` (Ubuntu's default local DNS cache) is listening on
`127.0.0.53` (the standard "stub resolver" address) and `127.0.0.54` (DoT
resolver).

### Root cause

The Linux socket layer treats a wildcard bind (`0.0.0.0:53`) and a
specific-IP bind (`127.0.0.53:53`) on the same port as conflicting. Even
though Pi-hole only wants the wildcard, the kernel returns `EADDRINUSE`
because something else already holds `127.0.0.53:53`.

### Fix

Disable systemd-resolved's stub listener. (We will re-point /etc/resolv.conf
at a real upstream, since /etc/resolv.conf normally aliases the now-disabled
127.0.0.53.)

```bash
sudo sed -i 's/^\s*#\?\s*DNSStubListener=.*/DNSStubListener=no/' \
    /etc/systemd/resolved.conf
sudo rm -f /etc/resolv.conf
sudo tee /etc/resolv.conf <<'EOF'
nameserver 1.1.1.1
nameserver 9.9.9.9
EOF
sudo systemctl restart systemd-resolved
```

Captured in `scripts/free-port-53.sh`.

### Lesson

On any Ubuntu / Debian-derivative host, anything running a local DNS
server (Pi-hole, Unbound, dnsmasq, k3s CoreDNS in some configurations)
will collide with systemd-resolved on port 53. This is the most common
Pi-hole / unbound install issue on Linux and the same pattern repeats
across countless production tickets. Always check `ss -tulnp | grep :53`
before installing a DNS service.

---

## Issue 3 — WSL2 DNS tunneling holding 10.255.255.254:53

**When**: After fixing Issue 2. Same `docker compose up -d` retry.

### Symptom

```
Error response from daemon: failed to bind host port 0.0.0.0:53/tcp:
  address already in use
```

(same error as Issue 2, even though systemd-resolved is now silent on 53)

### Investigation

```
$ ss -tulnp | grep ':53\b'
udp UNCONN 0 0  10.255.255.254:53  0.0.0.0:*
tcp LISTEN 0 1000  10.255.255.254:53  0.0.0.0:*
```

No PID, no user — the listener does not appear to be a Linux process.

```
$ ip -4 addr show
inet 10.255.255.254/32 scope global lo
```

The address `10.255.255.254/32` is bound on the **loopback** interface as
an alias. This is unusual: normal Linux loopback only carries 127.0.0.1.

### Root cause

WSL2's "DNS tunneling" feature: WSL routes the Linux side's DNS queries
through the Windows host's resolver. The listener is part of this proxy
and is owned by the WSL kernel-side virtio-dns layer, which is why
`ss -p` shows no userspace process. Linux still considers
`10.255.255.254:53` and `0.0.0.0:53` overlapping for binding purposes,
so Pi-hole can't take the wildcard.

### Fix

Disable DNS tunneling. This is a Windows-side WSL config in
`%USERPROFILE%\.wslconfig`:

```ini
[wsl2]
dnsTunneling=false
```

Then `wsl --shutdown` and re-launch.

After restart:

```
$ ip -4 addr show lo
inet 127.0.0.1/8 scope host lo            # 10.255.255.254 alias is gone
$ ss -tulnp | grep ':53\b'                # nothing
```

`docker compose up -d` succeeds.

### Lesson

When `ss -tulnp` shows a listener with no PID and no user on Linux, the
listener is in the kernel — for WSL2, that means a virtio backend.
WSL2-specific listeners can't be killed with `kill`; they have to be
disabled in `.wslconfig`.

This issue is **not searchable** under "Pi-hole port 53 in use" because
the symptom looks identical to Issue 2 even though the cause is in a
totally different layer (WSL tunneling rather than systemd-resolved).
Layer-by-layer port-binding investigation is the only reliable approach.

---

## Issue 4 — Pi-hole pod stuck in restart loop, killed by liveness probe during gravity database build

**When**: First k3s deployment of Pi-hole.

### Symptom

```
$ kubectl -n pihole get pods
NAME                      READY   STATUS    RESTARTS      AGE
pihole-6577784d84-k5wk2   0/1     Running   3 (36s ago)   4m18s

$ kubectl -n pihole logs deploy/pihole --tail=10
  [i] Status: Pending...
  [i] Container stop requested...
  [i] pihole-FTL is running - Attempting to shut it down cleanly
pihole-FTL: no process found
  [i] Container stop requested...
  [i] pihole-FTL is running - Attempting to shut it down cleanly
pihole-FTL: no process found
```

Pod kept restarting every ~60 seconds.

### Initial probes (too aggressive)

```yaml
livenessProbe:
  httpGet: { path: /admin/login, port: 80 }
  initialDelaySeconds: 60
  periodSeconds: 30
readinessProbe:
  httpGet: { path: /admin/login, port: 80 }
  initialDelaySeconds: 30
  periodSeconds: 10
```

(Default `timeoutSeconds: 1`, default `failureThreshold: 3`.)

### Root cause

Pi-hole on first run downloads and compiles the **gravity database** — a
combined adblock list, currently several MB and hundreds of thousands of
domains. On a slow disk or network, this takes 30–90 seconds. During the
build, the FTL daemon is alive but the web server is briefly unresponsive
because FTL holds a lock while the new SQLite file is rebuilt.

The 1-second probe timeout was tighter than the worst-case web response
time during gravity build. Three consecutive failures → kubelet
restarted the container → gravity build started over from scratch →
infinite loop.

### Fix

Add a `startupProbe` with a generous failure threshold and increase the
`timeoutSeconds` on liveness/readiness:

```yaml
startupProbe:
  httpGet: { path: /admin/login, port: 80 }
  initialDelaySeconds: 30
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 30          # up to 5 minutes of startup grace
livenessProbe:
  httpGet: { path: /admin/login, port: 80 }
  periodSeconds: 60
  timeoutSeconds: 5
  failureThreshold: 3
readinessProbe:
  httpGet: { path: /admin/login, port: 80 }
  periodSeconds: 15
  timeoutSeconds: 5
  failureThreshold: 3
```

After re-apply: pod went from `0/1 Running` (with restart count climbing)
to `1/1 Running` and stayed.

### Lesson

For workloads with a slow first-time setup phase (blocklist downloads,
schema migrations, AI model loads, large container caches), use
`startupProbe` with a high `failureThreshold`. Liveness and readiness
probes are not evaluated until startupProbe passes — this gives you a
long startup window without sacrificing run-time health checking.

Default `timeoutSeconds: 1` is too tight for any HTTP endpoint that ever
holds a lock. 5 seconds is a more realistic floor.

---

## Issue 5 — k3s pod sandbox flapping with hostPort on WSL2

**When**: After fixing Issue 4. Pod now had relaxed probes but still wasn't stable.

### Symptom

```
$ kubectl -n pihole describe pod -l app=pihole
Events:
  Normal Scheduled       3m32s default-scheduler  Successfully assigned ...
  Normal Pulled          3m31s kubelet            ...
  Normal Created         3m31s kubelet            Container created
  Normal Started         3m30s kubelet            Container started
  Normal SandboxChanged  41s   kubelet            Pod sandbox changed, killed and re-created
  Normal Pulled          40s   kubelet            ... already present ...
  Normal Created         39s   kubelet            Container created
  Normal Started         39s   kubelet            Container started
  Normal SandboxChanged  2s    kubelet            Pod sandbox changed, killed and re-created
```

`SandboxChanged` events firing every 30–60 seconds. Probes never had a chance.

The pod IP also changed each cycle: `10.42.0.30 → 10.42.0.33 → ...`.
DNS queries to the host port returned `connection refused`.

### Investigation

The deployment used `hostPort: 53` to bind UDP/TCP 53 on the host directly:

```yaml
ports:
  - { containerPort: 53, hostPort: 53, protocol: UDP }
  - { containerPort: 53, hostPort: 53, protocol: TCP }
  - { containerPort: 80, protocol: TCP }
```

`hostPort` is implemented by the CNI **portmap** plugin, which programs
DNAT rules in the host's iptables nat table:

```
$ sudo iptables -t nat -L | grep -A1 53
DNAT 17 -- 0.0.0.0/0 0.0.0.0/0 udp dpt:53 to:10.42.0.33:53
DNAT 6  -- 0.0.0.0/0 0.0.0.0/0 tcp dpt:53 to:10.42.0.33:53
```

DNAT rules existed but pointed at a stale pod IP from a previous sandbox.

k3s logs around the same window showed kubelet briefly losing API server
contact:

```
"Failed to update lease": connect: connection refused
```

— transient enough that systemd auto-restart and `kubelet` reconnected,
but during the gap, sandboxes were considered orphaned and recreated.

### Root cause (best understanding)

WSL2's network state is more dynamic than a real Linux host: the VM
responds to Windows-side network changes (Wi-Fi roaming, VPN connect,
sleep/wake). On state churn, k3s' kubelet plus CNI portmap appear to
re-evaluate sandbox network setup. The combination of (a) hostPort
DNAT requiring a stable pod IP, (b) WSL2 network churn, and (c) k3s'
fairly tight kubelet liveness margins produces a flapping sandbox.

### Fix

Switch the pod to `hostNetwork: true` and remove `hostPort`. With
hostNetwork, the pod runs in the host's network namespace directly —
the CNI portmap layer is bypassed entirely; there is no DNAT and no
pod-level IP to keep stable.

```yaml
spec:
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
  containers:
    - name: pihole
      ports:
        - { containerPort: 53, protocol: UDP }
        - { containerPort: 53, protocol: TCP }
        - { containerPort: 80, protocol: TCP }
```

After re-deploy:

```
$ kubectl -n pihole get pods -o wide
NAME                      READY   STATUS    RESTARTS   AGE   IP              NODE
pihole-675cdb46d5-g44h7   1/1     Running   0          56s   172.29.227.51   desktop-2k1nehl
```

Pod IP equals the host eth0 IP, confirming hostNetwork. 0 restarts after
5 minutes; ports 53 (UDP+TCP) and 80 (TCP) bound on `0.0.0.0`.

### Lesson

`hostNetwork: true` is the standard production pattern for
pod-as-network-service workloads (DNS, proxies, monitoring agents,
service meshes). It trades isolation for stability — the pod sees all
host interfaces and host-level network state directly.

On WSL2 specifically, hostPort is unreliable; hostNetwork is reliable.
On bare-metal or normal cloud VMs, both work, but hostNetwork is still
preferred for these workloads because it avoids one entire failure
surface (CNI portmap iptables management).

---

## Issue 6 — Pi-hole on WSL2 invisible to Windows host (UNRESOLVED, documented)

**When**: After all of the above. Goal: route Windows host's DNS through
the Pi-hole running in WSL2.

### Symptom matrix

| From | To | Result |
| --- | --- | --- |
| WSL2 | Pi-hole `127.0.0.1:53` UDP | works (`dig` returns 0.0.0.0 for ad domains) |
| Windows | WSL2 `172.29.227.51:53` UDP | times out |
| Windows | WSL2 `172.29.227.51:80` TCP | times out |
| Windows | `ping 172.29.227.51` | 100% loss |

### Why this matters

WSL2's default networking mode is NAT: the WSL VM is on its own virtual
switch and its IP is not routable from the Windows host for unsolicited
inbound traffic. Localhost forwarding is TCP-only and limited; UDP DNS
to WSL services does not work in NAT mode.

### Try 1 — WSL2 mirrored networking

Add to `~/.wslconfig`:

```ini
[wsl2]
dnsTunneling=false
networkingMode=mirrored
```

`wsl --shutdown` and re-launch. WSL VM now sees Windows' Wi-Fi adapter
directly:

```
$ ip -br -4 addr
lo               UNKNOWN  127.0.0.1/8
eth1             UP       192.168.0.5/24    # Windows LAN IP
```

Pi-hole pod (still hostNetwork) re-bound to 0.0.0.0:53 — which now
overlaps with the Windows host network stack. From Windows:

```
> Get-NetUDPEndpoint -LocalPort 53
0.0.0.0:53 → svchost (PID 4336)
```

A Windows-side process (svchost-hosted WSL relay) is listening on 53 —
the mirror layer is exposing the Pi-hole port. But:

```
> nslookup doubleclick.net 127.0.0.1
*** UnKnown can't find doubleclick.net: No response from server
> Invoke-WebRequest http://localhost/admin/login
The operation has timed out.
```

Connections accepted, no responses returned.

### Try 2 — Hyper-V firewall allow rules

Mirrored mode introduces a separate **Hyper-V firewall** layer. Default
rules:

```
> Get-NetFirewallHyperVRule | Where DisplayName -match WSL
WslCore Inbound ICMPv4 Default Allow
WslCore Inbound ICMPv6 Default Allow
WslCore Inbound IPv4 mDNS Default Allow
WslCore Inbound IPv6 mDNS Default Allow
```

Only ICMP and mDNS are allowed. Add explicit allow rules for the Pi-hole
ports (admin elevation required):

```powershell
$vmCreatorId = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
foreach ($r in @(
    @{ Name='WSL-Pihole-DNS-UDP'; Proto='UDP'; Port=53 },
    @{ Name='WSL-Pihole-DNS-TCP'; Proto='TCP'; Port=53 },
    @{ Name='WSL-Pihole-HTTP';    Proto='TCP'; Port=80 }
)) {
    New-NetFirewallHyperVRule -Name $r.Name -Direction Inbound `
        -VMCreatorId $vmCreatorId -Protocol $r.Proto `
        -LocalPorts $r.Port -Action Allow
}
```

(Captured in `scripts/add-pihole-firewall-rules.ps1`.)

Re-test from Windows: same timeout. Rules are present:

```
> Get-NetFirewallHyperVRule -Name WSL-Pihole-*
WSL-Pihole-DNS-TCP   Pi-hole DNS TCP/53     Allow
WSL-Pihole-DNS-UDP   Pi-hole DNS UDP/53     Allow
WSL-Pihole-HTTP      Pi-hole admin HTTP/80  Allow
```

But queries still time out.

### Hypothesis (unresolved)

The svchost-side relay is forwarding queries into the WSL VM, but
something in the mirror data path (likely related to source-address
rewriting or the Windows-side socket routing) is silently dropping the
return path. The Hyper-V firewall is not the cause at this point — it's
been opened. Reverting `networkingMode=mirrored` and going back to NAT
would restore "WSL works for Linux side; not reachable from Windows" —
acceptable as the lab's terminal state.

### State after experiment

`networkingMode=mirrored` was removed; `dnsTunneling=false` retained.
Hyper-V firewall rules left in place (harmless without mirrored mode).
Windows DNS restored to home router.

### Workarounds for the actual goal

For a self-hosted ad blocker that serves a Windows host (and ideally a
phone over Wi-Fi):

1. **Standalone hardware** — Mini PC / Raspberry Pi running Pi-hole,
   reachable on the LAN by IP. Configure router DHCP to advertise it.
   This is the answer the homelab community converges on.
2. **Docker Desktop on Windows** — Pi-hole in a Docker Desktop container
   with proper host networking. The Docker Desktop Linux VM has cleaner
   host-network integration than WSL2 mirrored mode.
3. **AdGuard for Windows** (commercial, system-level) if hardware /
   networking effort is not justified.

### Lesson

The diagnostic chain for "I can't reach a service" goes layer by layer:

  process bind → host network namespace → CNI / docker network →
  iptables / nftables → host network adapter → physical fabric →
  destination firewall → destination process

WSL2 inserts two extra layers between Linux and Windows: the **WSL
networking mode** (NAT vs mirrored) and the **Hyper-V firewall**. Both
behave differently from documented Linux behavior. WSL is a useful
development environment, but it is a tricky **production support
target** for any service that needs to be reachable across the
host/guest boundary.

When a lower layer rejects, the symptoms above it look identical to a
broken application. Distinguishing application problems from platform
problems is a core support-engineer judgement and the most common
"escalate vs. close" decision.
