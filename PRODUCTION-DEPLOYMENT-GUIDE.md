# n8n Production Deployment Guide — AWS EC2 t3.xlarge

## Target Infrastructure
- **Instance:** AWS EC2 t3.xlarge (4 vCPU, 16 GB RAM)
- **Workload:** 10–50 concurrent n8n workflows with AI agents
- **Services:** n8n, PostgreSQL 16, n8n Task Runners (JS + Python)

---

## 1. Summary of Key Changes

### Critical Security Fixes
| Issue | Current | Production |
|-------|---------|------------|
| DB credentials | Hardcoded `kamal@1991` | Env file with restricted permissions |
| Runner auth token | Hardcoded in CLI | Env file, rotated periodically |
| Encryption key | Hardcoded | Env file with restricted permissions |
| DB username/database | Personal name `kamal` | Service-specific names |
| PostgreSQL port | Exposed on 5432 | Internal network only (no `-p 5432:5432`) |
| Secure cookies | Disabled (`false`) | Enabled for HTTPS |

### Resource Allocation (16 GB total)
| Component | Memory Limit | CPU Limit | Rationale |
|-----------|-------------|-----------|-----------|
| OS + Podman overhead | ~1.5 GB | — | Kernel, systemd, container runtime |
| PostgreSQL | 4 GB | 1.5 CPU | Shared buffers + work_mem for concurrent queries |
| n8n (main) | 6 GB | 1.5 CPU | Node.js heap for workflow execution + webhook handling |
| n8n Task Runners | 3 GB | 1.0 CPU | Python/JS code execution with pandas/numpy |
| Safety margin | ~1.5 GB | — | Prevents OOM kills during peak |

### Performance Tuning
| Setting | Current | Production | Why |
|---------|---------|------------|-----|
| PG `shared_buffers` | Default (128 MB) | 1 GB | Standard: 25% of dedicated PG memory |
| PG `work_mem` | Default (4 MB) | 32 MB | Supports complex workflow queries with sorting |
| PG `effective_cache_size` | Default (4 GB) | 3 GB | Tells planner about available OS cache |
| PG `max_connections` | Default (100) | 60 | Right-sized; n8n uses pooling |
| n8n Node.js heap | Default (~1.7 GB) | 4096 MB | Prevents OOM on large workflow executions |
| Runner concurrency | 10 | 15 | Matches expected concurrent workflow volume |
| Runner task timeout | 300s | 600s | AI agent workflows can be long-running |
| Health check interval | 7200s (2 hrs!) | 30s | Detect failures within a reasonable window |

---

## 2. Audit of Current Configuration

### Development-Oriented Issues Found

1. **Health check interval of 7200s (2 hours)** — A failed PostgreSQL won't be detected for 2 hours. Production standard is 10–30s.

2. **No resource limits on any container** — All containers compete for the full 16 GB. Under load, any container could OOM-kill others.

3. **PostgreSQL exposed on port 5432** — No reason to expose the database port externally. Only n8n needs access via the internal network.

4. **No PostgreSQL tuning** — Running entirely on defaults (128 MB shared_buffers) wastes 15+ GB of available memory.

5. **No Node.js heap configuration** — n8n defaults to ~1.7 GB V8 heap, which is insufficient for 50 concurrent workflows with large payloads.

6. **`postgres:latest` tag** — Unpinned image tag means uncontrolled upgrades. Pin to `postgres:16` or `postgres:17`.

7. **Mixed Docker/Podman commands** — n8n and runners use `docker`, PostgreSQL uses `podman`. Standardize on one runtime.

8. **No log rotation or verbosity control** — Containers will fill disk over time.

9. **`N8N_SECURE_COOKIE=false`** — With HTTPS enabled (`N8N_PROTOCOL=https`), secure cookies should be enabled.

10. **Runner auto-shutdown timeout is empty** — `N8N_RUNNERS_AUTO_SHUTDOWN_TIMEOUT` is set but has no value.

---

## 3. File Structure

```
/opt/n8n-production/
├── docker-compose.yml          # Main orchestration
├── .env                        # Secrets (chmod 600)
├── postgres/
│   ├── postgresql.conf         # Production PG tuning
│   └── data/                   # PG data volume
├── n8n/
│   └── data/                   # n8n data volume
└── runners/
    ├── Dockerfile              # Custom runners image
    └── n8n-task-runners.json   # Runner configuration
```

---

## 4. Configuration Files

See the accompanying files in this package:
- `docker-compose.yml` — Full production compose file
- `.env` — Environment variables (update secrets before deploying)
- `postgresql.conf` — PostgreSQL production tuning
- `Dockerfile.runners` — Task runner image
- `n8n-task-runners.json` — Runner config
- `migrate.sh` — Automated migration script

---

## 5. Migration Steps (Manual)

If not using `migrate.sh`, follow these steps:

### Step 1: Backup existing data
```bash
# Backup PostgreSQL
podman exec Postgres pg_dumpall -U kamal > /tmp/n8n-pg-backup-$(date +%Y%m%d).sql

# Backup n8n data
tar czf /tmp/n8n-data-backup-$(date +%Y%m%d).tar.gz /opt/n8n/data
tar czf /tmp/pg-data-backup-$(date +%Y%m%d).tar.gz /home/kamal/containers/Postgres
```

### Step 2: Stop existing services
```bash
sudo systemctl stop Postgres.service
podman stop n8n n8n-runners 2>/dev/null
docker stop n8n n8n-runners 2>/dev/null
```

### Step 3: Create directory structure
```bash
sudo mkdir -p /opt/n8n-production/{postgres/data,n8n/data,runners}
sudo chown -R $USER:$USER /opt/n8n-production
```

### Step 4: Copy configuration files
```bash
cp docker-compose.yml .env /opt/n8n-production/
cp postgresql.conf /opt/n8n-production/postgres/
cp Dockerfile.runners n8n-task-runners.json /opt/n8n-production/runners/
chmod 600 /opt/n8n-production/.env
```

### Step 5: Migrate data
```bash
# Copy PostgreSQL data
cp -a /home/kamal/containers/Postgres/pgdata/* /opt/n8n-production/postgres/data/

# Copy n8n data
cp -a /opt/n8n/data/* /opt/n8n-production/n8n/data/
```

### Step 6: Update .env with your actual secrets
```bash
vim /opt/n8n-production/.env
# Update: DB_PASSWORD, N8N_ENCRYPTION_KEY, RUNNERS_AUTH_TOKEN
```

### Step 7: Build and launch
```bash
cd /opt/n8n-production
podman-compose build
podman-compose up -d
```

### Step 8: Verify
```bash
podman-compose ps
podman-compose logs -f --tail=50
# Check n8n UI at https://n8n.iitbacr.space
# Verify a test workflow runs successfully
```

---

## 6. Monitoring Recommendations

### Container health
```bash
# Check all container status
podman-compose ps

# Watch resource usage
podman stats --no-stream

# PostgreSQL connection count
podman exec n8n-postgres psql -U n8n -d n8n -c "SELECT count(*) FROM pg_stat_activity;"
```

### Log management
The compose file configures `json-file` logging with 10 MB rotation and 3 file retention per container. For production, consider shipping logs to CloudWatch:
```bash
# Install CloudWatch agent on EC2
# Or use fluentd/fluent-bit sidecar
```

### Recommended CloudWatch alarms
- CPU credit balance < 50 (t3 burst exhaustion)
- Memory utilization > 85%
- Disk utilization > 80%
- Container restart count > 0 in 5 minutes
