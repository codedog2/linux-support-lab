# linux-support-lab

A self-study lab built in preparation for an L1/L2 cloud-infrastructure
support role on the Linux + Kubernetes stack. The project deploys the same
real workload (a Pi-hole DNS sinkhole) two ways on a single Linux host —
once with Docker Compose, once with a Kubernetes manifest set running on
k3s — and documents every issue I hit while building it.

The most useful artifacts here are not the manifests; they are the
**troubleshooting log** (`notes/03-troubleshooting-log.md`) and the
diagnostic script (`scripts/diag.sh`), which capture the diagnostic
methodology I would bring to a support engineer role.

## Stack

| Layer | Component | Version |
| --- | --- | --- |
| OS | Ubuntu | 24.04.3 LTS (Noble) |
| Kernel | Linux | 6.6.87 (WSL2) |
| Container runtime | Docker Engine | 29.4.2 |
| Compose | docker compose | v5.1.3 |
| Orchestrator | k3s | v1.35.4 |
| Workload | Pi-hole (FTL) | 2025.10.0 (v6.3) |

## Repo layout

```
linux-support-lab/
├── docker/
│   └── docker-compose.yml         # Pi-hole, single-container baseline
├── k3s/
│   └── pihole.yaml                # Pi-hole on k3s: Namespace + ConfigMap +
│                                  #   Secret + Deployment + Service
├── scripts/
│   ├── install-docker.sh          # docker-ce install on Ubuntu 24.04
│   ├── free-port-53.sh            # disable systemd-resolved stub listener
│   ├── set-pihole-dns.ps1         # Windows DNS -> Pi-hole (admin, optional)
│   ├── restore-dns.ps1            # Windows DNS restore (admin)
│   ├── add-pihole-firewall-rules.ps1   # Hyper-V firewall allow-rules
│   └── diag.sh                    # Linux one-shot system health snapshot
├── notes/
│   ├── 01-virtualization-stack.md # KVM / OpenVZ / Docker / K8s comparison
│   ├── 02-l1-runbook.md           # common symptom -> command -> read
│   └── 03-troubleshooting-log.md  # six real issues from this build
└── README.md
```

## Reproducing the lab

Targets WSL2 Ubuntu 24.04 but works on any Linux host with Docker support.
All commands assume bash and are run from the repo root.

1. Install Docker Engine + compose plugin
   ```
   sudo bash scripts/install-docker.sh
   ```

2. Free port 53 (disable systemd-resolved DNS stub listener)
   ```
   sudo bash scripts/free-port-53.sh
   ```

3a. Docker Compose path
   ```
   cd docker && docker compose up -d
   curl -L http://127.0.0.1:8080/admin/login   # web UI
   dig @127.0.0.1 doubleclick.net              # should return 0.0.0.0
   ```

3b. k3s path (lightweight Kubernetes — assumes Docker Compose path stopped first)
   ```
   curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='--disable=traefik --disable=servicelb --write-kubeconfig-mode=644' sh -
   sudo install -m 644 -o $USER /etc/rancher/k3s/k3s.yaml ~/.kube/config
   kubectl apply -f k3s/pihole.yaml
   kubectl -n pihole wait --for=condition=ready pod -l app=pihole --timeout=180s
   dig @127.0.0.1 doubleclick.net
   curl -L http://127.0.0.1/admin/login
   ```

4. Capture a system health snapshot
   ```
   sudo bash scripts/diag.sh > diag-$(hostname)-$(date +%FT%H%M).txt
   ```

## Why two deployment methods

Same workload, two layers of abstraction.

- **Docker Compose** is the "single host, single tool" baseline. Easiest to
  reason about, no orchestration overhead, no scheduler. This is what most
  small VPS deployments look like in practice.
- **k3s + manifest set** is the "one node, full Kubernetes API" version.
  The Deployment, Service, ConfigMap, and Secret resources here are the
  same primitives Virtuozzo's customers use on Kubernetes-as-a-Service
  platforms. The cost: more moving parts, more failure modes, more
  diagnostic surface area.

The troubleshooting log shows what was different between the two — the
Docker version came up cleanly; the k3s version surfaced a CNI / hostPort
interaction on WSL2 that took two re-deploys to find. That's the value of
running both: you see where each layer fails in a way the other doesn't.

## What I learned

The most useful parts of this exercise were the failures.
See `notes/03-troubleshooting-log.md` — six independent issues across
WSL1→WSL2 conversion, systemd-resolved, WSL2 DNS tunneling, Pi-hole
startup probes, k3s CNI on WSL2, and Hyper-V firewall under mirrored
networking. Each entry is symptom → investigation → root cause → fix →
lesson, captured at the time I hit it.

## Status & honest scope

This is a self-study artifact, not a production deployment. The Pi-hole
instance only blocks ads for the Linux side of WSL2 — making it serve a
Windows host or a phone over Wi-Fi requires either standalone hardware or
a more substantial WSL2 mirrored-networking + Hyper-V firewall setup, which
is documented as an unresolved issue in the troubleshooting log.

Notes in `notes/01-virtualization-stack.md` are study notes synthesized
from the Linux man pages, official KVM / OpenVZ documentation, and the
Kubernetes concept docs while preparing for LPIC-1.

## Author

Yaowei Feng
