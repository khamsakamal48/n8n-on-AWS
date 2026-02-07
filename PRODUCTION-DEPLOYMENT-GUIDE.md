# n8n Production Deployment Guide — AWS EC2 t3.xlarge (Podman)

## Target Infrastructure
- **Instance:** AWS EC2 t3.xlarge (4 vCPU, 16 GB RAM)
- **Container runtime:** Podman with podman-compose
- **Workload:** 10–50 concurrent n8n workflows with AI agents
- **Services:** n8n, PostgreSQL 16, n8n Task Runners (JS + Python), Watchtower (monitor)

---

## Podman Compatibility Notes

This stack is written specifically for Podman. Key differences from Docker:

| Feature | Docker Compose | This Stack (Podman) |
|---------|----------------|---------------------|
| Volume driver_opts | Supported | **Not supported** — uses direct bind mounts |
| depends_on + service_healthy | Works | **Broken** — uses simple depends_on + restart policy |
| Container socket | /var/run/docker.sock | Auto-detected rootful/rootless Podman socket |
| Watchtower image | containrrr/watchtower | **nickfedor/watchtower** (maintained fork) |
| Resource limits (deploy) | Supported | Supported (cgroups v2 required) |
| SELinux labels (:Z) | Optional | Required on SELinux-enabled hosts |

### Pre-requisites
```bash
# Verify cgroups v2 (required for memory/CPU limits)
mount | grep cgroup2

# Enable Podman socket (required for Watchtower)
sudo systemctl enable --now podman.socket   # rootful
# or
systemctl --user enable --now podman.socket  # rootless
```

---

## Resource Allocation (16 GB total)

| Component | Memory Limit | CPU Limit | Rationale |
|-----------|-------------|-----------|-----------|
| OS + Podman overhead | ~1.5 GB | — | Kernel, systemd, container runtime |
| PostgreSQL | 4 GB | 1.5 CPU | shared_buffers(1GB) + work_mem + connections |
| n8n (main) | 6 GB | 1.5 CPU | Node.js heap(4GB) + native allocations |
| n8n Task Runners | 3 GB | 1.0 CPU | Python/JS code execution (pandas/numpy) |
| Watchtower | 128 MB | 0.1 CPU | Lightweight image checker |
| Safety margin | ~1.4 GB | — | Prevents OOM kills during peak |

---

## File Structure

```
/opt/n8n-production/
├── docker-compose.yml          # Main orchestration
├── .env                        # Secrets + socket path (chmod 600)
├── deploy.sh                   # Automated deployment script
├── postgres/
│   ├── postgresql.conf         # Production PG tuning
│   ├── init/
│   │   └── 01-init-n8n.sql    # First-boot DB setup
│   └── data/                   # PG data (auto-created)
├── n8n/
│   └── data/                   # n8n data (auto-created)
└── runners/
    ├── Dockerfile              # Custom runners image
    └── n8n-task-runners.json   # Runner config
```

---

## Quick Start

```bash
# 1. Copy files to server
scp -r n8n-production/ ec2-user@your-server:/tmp/

# 2. Run deployment
ssh ec2-user@your-server
cd /tmp/n8n-production
chmod +x deploy.sh
./deploy.sh
```

The script handles: socket detection, secret generation, directory setup, staged startup (PG → n8n → runners → watchtower), and health verification.

---

## Service Startup Order

Since `depends_on: condition: service_healthy` is broken in podman-compose, startup order is handled by:

1. **deploy.sh** starts services sequentially with wait pauses
2. **restart: unless-stopped** ensures services that start before dependencies are ready will automatically retry
3. **n8n** has built-in DB connection retry logic
4. **n8n-runners** auto-reconnects to the broker

After initial deployment, `podman-compose up -d` starts all services. The restart policy handles any race conditions.

---

## Update Workflow

Watchtower runs in **monitor-only mode** — it checks for new images daily and logs findings but never auto-updates.

```bash
# Check for available updates
podman-compose logs watchtower

# Update a specific service
cd /opt/n8n-production
podman-compose pull n8n                # Pull new image
podman-compose up -d n8n               # Recreate with new image

# Update PostgreSQL (minor versions only — major requires pg_upgrade)
podman-compose pull postgres
podman-compose up -d postgres

# Rebuild runners (after changing Dockerfile or dependencies)
podman-compose build n8n-runners
podman-compose up -d n8n-runners
```

---

## Monitoring

```bash
# Real-time resource usage
podman stats --no-stream

# Container status
podman-compose ps

# Logs (follow)
podman-compose logs -f n8n
podman-compose logs -f postgres

# PostgreSQL connections
podman exec n8n-postgres psql -U n8n -d n8n \
  -c "SELECT count(*) FROM pg_stat_activity;"

# Check t3 CPU credit balance (from EC2 host)
aws cloudwatch get-metric-statistics \
  --namespace AWS/EC2 \
  --metric-name CPUCreditBalance \
  --dimensions Name=InstanceId,Value=i-YOUR-INSTANCE-ID \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 --statistics Average
```

### Recommended CloudWatch Alarms
- CPU credit balance < 50 (t3 burst exhaustion)
- Memory utilization > 85%
- Disk utilization > 80%
- Container restart count > 0 in 5 minutes
