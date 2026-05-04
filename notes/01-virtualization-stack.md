# The Linux virtualization & orchestration stack

Study notes synthesized from Linux man pages, the KVM / OpenVZ project
documentation, the Kubernetes concept docs, and the Pi-hole and k3s
project documentation while preparing for LPIC-1.

Contents:
1. KVM
2. OpenVZ (and how it relates to today's Linux containers)
3. Docker
4. Kubernetes
5. How they stack — when each layer is the right tool
6. Why this matters for support work on Virtuozzo's product line

---

## 1. KVM (Kernel-based Virtual Machine)

**One sentence**: KVM turns the Linux kernel itself into a hypervisor;
each VM is a regular Linux process running guest code with hardware
assistance.

### Mechanism

- KVM is a **kernel module** (`/dev/kvm`), in mainline since Linux 2.6.20
  (2007).
- Requires CPU hardware virtualization extensions: **Intel VT-x** or
  **AMD-V**.
- KVM handles **CPU and memory virtualization**. Device emulation
  (disk, network, console, USB) is handled by **QEMU** in userspace.
- Each VM is a Linux process; standard Linux scheduling and cgroups
  apply.
- Provides **full virtualization** — guest OS can be Linux, Windows,
  BSD, etc.

### Trap-and-emulate model

When the guest executes a privileged instruction (e.g. `cli`, page
table modification, I/O port access), the CPU triggers a **VM-Exit**:
control transfers to the host kernel's KVM module, which inspects the
exit reason, emulates the operation safely (often delegating to QEMU
for I/O), then issues a **VM-Entry** to resume the guest.

### Management

- **libvirt** is the standard C API and daemon (`libvirtd`).
- `virsh` is the CLI; `virt-manager` is the GUI.
- VMs are described by XML domain files; disks by qcow2 or raw images.

### Trade-offs

| | KVM |
| --- | --- |
| Isolation | Strong (hardware-level, separate kernel per VM) |
| Density | ~tens of VMs per host |
| Performance overhead | 5–15% (very good for full virt) |
| Boot time | 30 seconds – 1 minute |
| Memory overhead | Each VM has its own kernel + userspace |
| Use cases | Mixed-OS guests, security-sensitive multi-tenant, classic enterprise virtualization |

---

## 2. OpenVZ

**One sentence**: OpenVZ is OS-level virtualization for Linux — multiple
isolated user-space environments share a single host kernel, looking and
behaving like independent Linux servers.

### History and lineage

- Released 2005 by SWsoft (now Virtuozzo). Predates Docker (2013) by
  ~8 years and predates Linux mainline `cgroups` (2007) and most
  namespace types (2008–2013).
- Many of the kernel features that make modern Linux containers possible
  (especially PID, network, mount namespaces, and resource control)
  draw on work originally done in the OpenVZ kernel patchset.

### Mechanism

- **One** host Linux kernel, **N** containers (called Virtual
  Environments or `VE`s, also `CT`s).
- Containers run only Linux user space — they **must** be the same
  kernel as the host.
- Implemented via **Linux namespaces** (PID, mount, UTS, IPC, network,
  user, cgroup) for isolation, **cgroups** for resource limits, plus
  Virtuozzo's kernel patches for vSwap, second-level disk quotas, and
  beancounters.
- The **CRIU** project (Checkpoint/Restore In Userspace) was developed
  by the OpenVZ team and enables container live migration.

### Trade-offs vs. KVM

| Property | OpenVZ | KVM |
| --- | --- | --- |
| Layer | OS-level | Hardware-level |
| Kernel | shared (host's) | per-VM |
| Guest OS | Linux only | any |
| Density | 100s of containers per host | 10s of VMs per host |
| Boot time | 1–3 seconds | 30s – 1 min |
| Performance overhead | 1–3% | 5–15% |
| Isolation | weaker (shared kernel) | strong |
| Best for | dense Linux VPS hosting | mixed-OS or trust-sensitive workloads |

### Where OpenVZ fits today

OpenVZ-as-such is a niche product mostly seen at hosting providers that
buy commercial Virtuozzo. The **technologies** OpenVZ pioneered are
everywhere: Docker, LXC, Podman, and Kubernetes all use Linux
namespaces and cgroups, the same primitives OpenVZ helped mature.

---

## 3. Docker

**One sentence**: Docker is a packaging and runtime layer on top of
Linux containers — it standardizes how an application + its dependencies
are described, shipped, and run.

### What Docker actually is

Docker is **not** a virtualization technology. It is:

1. A **container runtime** (originally LXC-based, now `containerd` +
   `runc`) that uses Linux namespaces and cgroups under the hood.
2. An **image format** (layered tarballs with metadata) and the registry
   protocol for distributing them.
3. A **CLI** (`docker`) and daemon (`dockerd`) that orchestrate the
   above on a single host.

### Container vs. VM (summary)

| | VM (KVM) | Container (Docker) |
| --- | --- | --- |
| Kernel | own | shared with host |
| Boot | seconds–minutes | milliseconds |
| Image size | GBs (full OS) | MBs–hundreds of MBs (app + deps) |
| Density per host | tens | hundreds |
| Workload | full OS | typically a single process / app |

### Container vs. system container

Docker promotes the **application container** model: one container per
microservice, ephemeral, restart-friendly. OpenVZ-style **system
containers** are long-lived and contain a full Linux user space —
`init`, `cron`, `sshd`, multiple services. Both use the same kernel
mechanisms; the difference is operational philosophy.

LXC and Podman tend to be more comfortable for system-container
patterns; Docker dominates application-container patterns.

---

## 4. Kubernetes (and k3s)

**One sentence**: Kubernetes is a control plane that schedules and
manages container workloads across many host machines, with declarative
desired-state and continuous self-healing.

### What problem it solves

Single-host Docker is fine for a few containers. Once you have:

- 100+ machines running 1000+ containers
- Workloads that must auto-restart on failure
- Need for rolling updates without downtime
- Service discovery between dynamic pods
- Resource fairness across teams

…you need an orchestrator. Kubernetes is what came out of Google's
internal **Borg** system, open-sourced in 2014.

### Architecture (essentials)

- **Control plane**: API server, etcd (state store), scheduler, multiple
  controller managers. Speaks REST + watches for changes.
- **Workers**: each runs **kubelet** (node agent), **kube-proxy**
  (network), and a container runtime (`containerd`/`CRI-O`).
- **Reconciliation loop**: every controller continuously compares
  *desired state* (in etcd) to *actual state* (on the cluster) and
  acts to close the gap.

### Core abstractions

| Object | Purpose |
| --- | --- |
| **Pod** | Smallest scheduling unit. 1+ containers sharing network and storage. |
| **Deployment** | Manages a `ReplicaSet`; provides rolling updates and "I want N pods of this kind". |
| **Service** | Stable IP / DNS for a (changing) set of Pods. Types: ClusterIP, NodePort, LoadBalancer. |
| **ConfigMap** | Non-secret config delivered to Pods via env or files. |
| **Secret** | Same, for sensitive material; base64-encoded but not encrypted by default. |
| **Namespace** | Logical scoping, multi-tenancy, RBAC boundary. |
| **PersistentVolume / PVC** | Storage abstraction decoupled from the underlying implementation. |
| **DaemonSet** | One Pod per node (e.g. log shipper, node exporter). |
| **StatefulSet** | Stable identity + ordered rollout for stateful apps (databases). |
| **Ingress** | HTTP/S routing rules into the cluster. |

### k3s

A lightweight, single-binary Kubernetes distribution by Rancher (now
SUSE). Same API as upstream Kubernetes, but:

- Single binary (~70 MB)
- Replaces etcd with **kine** + SQLite for single-node simplicity
  (multi-node setups can use external etcd or embedded)
- Bundled CNI (flannel) and ingress (Traefik), both optional
- Uses `containerd` as the runtime; `kubectl` works identically

k3s is the most common choice for edge / homelab / single-node
Kubernetes because it is operationally cheap. The lab in this repo runs
k3s; everything in this section about Kubernetes applies.

---

## 5. How the layers stack

```
┌──────────────────────────────────────┐
│  Application (your business code)    │
├──────────────────────────────────────┤
│  Kubernetes (orchestration)          │  ← k3s in this lab
├──────────────────────────────────────┤
│  Container runtime                    │  ← containerd / docker
├──────────────────────────────────────┤
│  Linux kernel                         │
│    - namespaces (isolation)           │
│    - cgroups (resource control)       │
│    - netfilter / iptables (network)   │
├──────────────────────────────────────┤
│  Optional: KVM VM  -or-  OpenVZ CT    │  ← virtualization
├──────────────────────────────────────┤
│  Bare metal hardware                  │
└──────────────────────────────────────┘
```

You don't always use every layer:

- **Single Linux server**: skip K8s and virtualization. `apt install
  pihole`, done.
- **Single host with multiple workloads**: add Docker, run with
  docker-compose. (This lab's `docker/` path.)
- **Multiple hosts, complex dependencies, autoscaling**: add Kubernetes
  on top of Docker. (This lab's `k3s/` path.)
- **Hosting provider running mixed customer workloads**: add KVM and/or
  OpenVZ at the bottom to slice each physical machine into many
  customer-facing units. (Virtuozzo's product space.)

### Choosing virtualization vs. containers

| Question | If yes → |
| --- | --- |
| Need to run non-Linux guests? | KVM (only option) |
| Strong isolation between tenants? | KVM preferred, OpenVZ acceptable |
| Maximum density per physical host? | OpenVZ / containers |
| Workloads need to be portable across hosts? | Docker / Kubernetes |
| Need orchestrated rolling updates / autoscale? | Kubernetes |
| Single low-traffic service on a single box? | Docker Compose, no K8s |

---

## 6. Why this matters for Virtuozzo support work

Virtuozzo's product line covers all four layers above:

- **Virtuozzo Hybrid Server** — KVM + OpenVZ-style containers on the
  same host. Customers (CSPs, hosting providers) sell both VMs and
  Linux VPS containers from the same physical infrastructure.
- **Virtuozzo Hybrid Infrastructure** — OpenStack-based control plane.
  Adds KVM-as-a-Service, container-as-a-Service, software-defined
  storage, software-defined networking.
- **Virtuozzo Application Platform** — PaaS layer.
- **Kubernetes-as-a-Service** — managed K8s on top of the above.

A support engineer's tickets cross all of these layers in a typical
week. The diagnostic skill that matters most is **layer separation**:
when a customer says "my app is slow", knowing whether the bottleneck
is at the application code, container runtime, KVM trap-and-emulate
overhead, software-defined storage, or the underlying physical SAN.
Each layer has its own diagnostic tools and its own "normal" — knowing
each one's idiom is what separates a senior support engineer from a
junior one.
