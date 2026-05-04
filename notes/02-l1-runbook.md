# L1 / L2 Linux runbook

A short reference of the diagnostic commands an L1 engineer runs in the
first five minutes of any new Linux ticket. Organized by symptom.

Each command was run on the lab host (Ubuntu 24.04 LTS / Linux 6.6.87)
during the build of this repo. None of these are aspirational — every
output format below is what you'll actually see.

If you're triaging a real ticket and don't know where to start: run
`scripts/diag.sh` first, attach the output, then narrow down using the
sections below.

---

## 1. "What is the state of this box right now?"

### Identity & uptime
```bash
hostnamectl                          # hostname, OS, kernel, virtualization type
uname -a                             # kernel + arch (fallback if hostnamectl absent)
cat /etc/os-release                  # distribution name, version
uptime -p                            # how long has it been up
who                                  # who is logged in
```

### Resource snapshot
```bash
top -b -n 1 | head -20               # one-shot top, scriptable
free -h                              # memory + swap, human-readable
df -h                                # disk usage per mount
df -i                                # inode usage (don't forget this one)
```

**Read**:
- `top` `load average` line: 1m / 5m / 15m. Should be ≤ #cores under
  normal load. Persistently > #cores means CPU-bound.
- `free -h`: `available` is what matters, not `free`. Linux uses spare
  memory for cache; that's healthy.
- `df -h`: any filesystem ≥ 90% full is going to bite you within
  hours. `df -i` separately — running out of inodes is rarer but the
  symptom (`No space left on device` while `df -h` shows free space)
  baffles people.

---

## 2. "Is the network actually working?"

### Local
```bash
ip -br -4 addr                       # interfaces + IPv4, one line each
ip -4 route show                     # routing table
ip -4 route show default             # which interface is the default gateway?
cat /etc/resolv.conf                 # DNS servers in use
```

### Reachability ladder (ping, trace, dns, http)
```bash
ping -c 3 8.8.8.8                    # 1: do I have any network?
ping -c 3 google.com                 # 2: does DNS resolve too?
dig google.com                       # 3: full DNS detail
dig @1.1.1.1 google.com              # 4: bypass local resolver
traceroute -n 1.1.1.1                # 5: path to the target
curl -I https://www.google.com       # 6: TLS handshake + HTTP headers
```

If `ping 8.8.8.8` works but `ping google.com` doesn't → DNS issue.
If `dig @1.1.1.1` works but `dig` (no @) doesn't → local resolver issue.

### Ports & sockets
```bash
ss -tulnp                            # listening TCP/UDP sockets + processes
ss -tnp                              # established TCP connections
ss -s                                # summary counts
sudo netstat -tulnp                  # legacy equivalent (often not installed by default on modern Ubuntu)
```

**Read**: `LISTEN 0.0.0.0:80` = "listening on every interface, port 80".
A specific IP like `127.0.0.1:80` means "loopback only — local
connections, not LAN".

---

## 3. "Why is this process eating resources?"

### Find the offender
```bash
ps -eo pid,user,pcpu,pmem,rss,comm --sort=-pcpu | head    # by CPU
ps -eo pid,user,pcpu,pmem,rss,comm --sort=-rss  | head    # by memory
top -b -n 1 -o %CPU | head -15
htop                                                       # interactive (if installed)
```

### Inspect a specific PID
```bash
ps -fp <PID>                         # command line + parent
cat /proc/<PID>/status               # detailed (RSS, VmPeak, threads, signals)
cat /proc/<PID>/cmdline | tr '\0' ' '; echo   # full command line, NUL-separated
ls -l /proc/<PID>/exe                # binary path
sudo lsof -p <PID>                   # open files / sockets
sudo strace -p <PID>                 # live syscall trace (Ctrl-C to stop)
```

---

## 4. "What broke recently?"

### Kernel ring buffer
```bash
dmesg -T | tail -30                  # last 30 kernel messages with timestamps
dmesg -T | grep -iE 'oom|kill|err|fail|denied'  # filter to interesting events
```

`OOM killer` selecting and killing a process is the single most common
"my service silently disappeared" cause on memory-constrained hosts.
`Out of memory: Killed process ...` in dmesg is unambiguous.

### systemd journal
```bash
journalctl -xeu <unit>               # full log for one unit, with explanations
journalctl --since "1 hour ago" --priority=err   # all errors in last hour
journalctl -fu <unit>                # tail (-f) follow mode
journalctl -k --since today          # kernel-only messages today
```

### Service state
```bash
systemctl status <unit>              # current state + last 10 log lines
systemctl is-active <unit>           # one-word answer (active/inactive/failed)
systemctl list-units --failed        # everything currently failed
systemctl list-unit-files --state=enabled   # what's set to start at boot
```

---

## 5. "Disks and storage"

```bash
df -h                                # what's mounted, how full
df -i                                # inode usage
du -sh /var/log /tmp /home/*         # who's using the space
mount | grep -v ' /sys\| /proc\| /run'   # actual filesystem mounts
lsblk -f                             # block devices + filesystems + UUIDs
sudo smartctl -H /dev/sda            # drive health (SMART). PASSED is good.
```

If `du` is taking forever on a large directory:
```bash
sudo ncdu /                          # interactive disk-usage explorer (apt install ncdu)
```

---

## 6. "Container & Kubernetes layer"

### Docker
```bash
docker ps                            # running containers
docker ps -a                         # incl. stopped
docker logs <name> --tail=50         # last 50 lines from a container
docker logs -f <name>                # tail (-f) follow
docker stats --no-stream             # one-shot CPU/mem per container
docker inspect <name>                # full JSON state
docker exec -it <name> bash          # shell into a running container
```

Common Docker symptoms:
- "Container won't start, exits immediately" → `docker logs <name>` —
  almost always tells you the problem in plain English.
- "Container Up but service not reachable" → check port mapping
  (`docker port <name>`) and that the app inside is bound to `0.0.0.0`,
  not `127.0.0.1`.

### Kubernetes (works on k3s identically)
```bash
kubectl get nodes                                  # are nodes Ready?
kubectl get pods -A                                # all pods, all namespaces
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
                                                   # only the unhappy ones
kubectl describe pod -n <ns> <pod>                 # events + state + probe status
kubectl logs -n <ns> <pod> --tail=50               # pod stdout/stderr
kubectl logs -n <ns> <pod> --previous              # previous container instance (after a restart)
kubectl get events -n <ns> --sort-by=.lastTimestamp | tail -20
kubectl exec -n <ns> -it <pod> -- bash             # shell into a pod
kubectl top pod -n <ns>                            # CPU/mem (needs metrics-server)
kubectl top node
```

The 80/20 rule for Kubernetes triage:
- Pod stuck `Pending` → `describe pod`, look at the `Events` section.
  Almost always a scheduling issue (no node has enough resources, no
  matching node selector, PVC not bound).
- Pod in `CrashLoopBackOff` → `logs --previous`, that's the crash reason.
- Pod `Running` but `0/N Ready` → readiness probe is failing.
  `describe pod` shows the probe response code.

---

## 7. "Bonus: a one-shot for ticket attachments"

`scripts/diag.sh` in this repo runs through the highest-value checks
above and produces a single text snapshot. Run it as the first thing on
a new ticket:

```bash
sudo bash diag.sh > diag-$(hostname)-$(date +%FT%H%M).txt
```

Attach the output. Half the tickets are then resolvable from the
snapshot alone; the other half are at least scoped within five minutes
instead of fifty.

---

## Appendix: tool synonyms

You will see different commands for the same job depending on
distribution and era. Modern equivalents are listed first.

| Job | Modern | Older / fallback |
| --- | --- | --- |
| List sockets | `ss -tulnp` | `netstat -tulnp` |
| List interfaces | `ip -br addr` | `ifconfig -a` |
| Routing table | `ip route` | `route -n` |
| Init / services | `systemctl ...` | `service ...`, `/etc/init.d/...` |
| Logs | `journalctl ...` | `tail -f /var/log/...` |
| Process tree | `ps -eo ...` | `pstree`, `ps auxf` |
| Disk I/O snapshot | `iostat -xz 1` (sysstat) | `vmstat 1` |

When in doubt, look in `/proc/<pid>/` and `/sys/` — the kernel exposes
almost everything as files there.
