# n8n Production Deployment Guide — AWS EC2 t3.xlarge (Podman)

## Target Infrastructure
- **Instance:** AWS EC2 t3.xlarge (4 vCPU, 16 GB RAM)
- **Container runtime:** Podman with podman-compose
- **Workload:** 10–50 concurrent n8n workflows with AI agents
- **Services:** n8n, PostgreSQL 16, Redis 7, n8n Task Runners (JS + Python), Docling Serve (document API)

---

## Podman Compatibility Notes

This stack is written specifically for Podman. Key differences from Docker:

| Feature | Docker Compose | This Stack (Podman) |
|---------|----------------|---------------------|
| Volume driver_opts | Supported | **Not supported** — uses direct bind mounts |
| depends_on + service_healthy | Works | **Broken** — uses simple depends_on + restart policy |
| Image update checks | Watchtower container | **systemd timer** + `check-updates.sh` (Podman-native) |
| Resource limits (deploy) | Supported | Supported (cgroups v2 required) |
| SELinux labels (:Z) | Optional | Required on SELinux-enabled hosts |

### Pre-requisites
```bash
# Verify cgroups v2 (required for memory/CPU limits)
mount | grep cgroup2
```

---

## Resource Allocation (16 GB total)

| Component | Memory Limit | CPU Limit | Rationale |
|-----------|-------------|-----------|-----------|
| OS + Podman overhead | ~1.5 GB | — | Kernel, systemd, container runtime |
| PostgreSQL | 4 GB | 1.5 CPU | shared_buffers(1GB) + work_mem + connections |
| Redis | 768 MB | 0.3 CPU | In-memory chat history + 512MB maxmemory cap |
| n8n (main) | 6 GB | 1.5 CPU | Node.js heap(4GB) + native allocations |
| n8n Task Runners | 3 GB | 1.0 CPU | Python/JS code execution (pandas/numpy) |
| Docling Serve | *uncapped* | *uncapped* | Limits commented out — enable after tuning |
| Safety margin | ~0.6 GB | — | Prevents OOM kills during peak |

> **Note on Docling:** Resource limits for Docling are commented out in docker-compose.yml. Once you observe real-world usage with `podman stats --no-stream`, uncomment and set limits. Suggested starting point: 4 GB memory, 2.0 CPU. When enabling Docling limits, reduce n8n to 4 GB and runners to 2 GB to stay within the 16 GB envelope.

---

## File Structure

```
/opt/n8n-production/
├── docker-compose.yml          # Main orchestration (5 services)
├── .env                        # Secrets (chmod 600)
├── deploy.sh                   # Automated deployment script
├── check-updates.sh            # Image update checker (runs via systemd timer)
├── postgres/
│   ├── postgresql.conf         # Production PG tuning
│   ├── init/
│   │   └── 01-init-n8n.sql    # First-boot DB setup
│   └── data/                   # PG data (auto-created)
├── redis/
│   └── data/                   # Redis AOF + RDB persistence
├── n8n/
│   └── data/                   # n8n data (auto-created)
├── runners/
│   ├── Dockerfile              # Custom runners image
│   └── n8n-task-runners.json   # Runner config
├── docling/
│   ├── download-models.sh      # Pre-download VLM models (run after deploy)
│   ├── hf-cache/               # HuggingFace model cache (auto-populated)
│   ├── models/                 # Docling pipeline model artifacts
│   └── documents/              # Shared document I/O directory
└── systemd/
    ├── n8n-stack.service             # Auto-start service (starts on boot)
    ├── n8n-check-updates.service     # Oneshot service for update checks
    └── n8n-check-updates.timer       # Daily timer trigger
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

# 3. Download Docling VLM models (wait ~2 min for Docling to boot first)
cd /opt/n8n-production
./docling/download-models.sh
```

The script handles: secret generation, directory setup, systemd timer installation, staged startup (PG + Redis → n8n → runners + Docling), and health verification.

---

## Service Startup Order

Since `depends_on: condition: service_healthy` is broken in podman-compose, startup order is handled by:

1. **deploy.sh** starts services sequentially with wait pauses
2. **restart: always** ensures services that start before dependencies are ready will automatically retry
3. **n8n** has built-in DB connection retry logic
4. **n8n-runners** auto-reconnects to the broker
5. **Redis** and **Docling Serve** are independent services — no ordering dependencies

After initial deployment, `podman-compose up -d` starts all services. The restart policy handles any race conditions.

---

## Redis — Chat Memory & Workflow Cache

### Why Redis?

Redis is the recommended backend for n8n's **Redis Chat Memory** LangChain node, which persists AI agent conversation history across workflow runs. Without Redis, chat memory only lives in the workflow execution context and is lost when the workflow completes.

Key benefits for n8n:
- **Persistent chat history**: Conversations survive workflow restarts and n8n upgrades
- **Session isolation**: Each chat/user gets a unique session key — multiple chatbots can share one Redis
- **Sub-millisecond reads**: Conversation context is retrieved instantly
- **TTL support**: Auto-expire stale conversations to manage memory
- **Workflow caching**: Also usable via the Redis node for rate limiting, deduplication, and temporary data sharing between workflows

### Configuration in n8n

1. Go to **Credentials** → **New Credential** → **Redis**
2. Set:
   - **Host:** `n8n-redis`
   - **Port:** `6379`
   - **Password:** (from `.env` file → `REDIS_PASSWORD`)
   - **Database:** `0` (default)
3. In your AI agent workflow, add a **Redis Chat Memory** sub-node and select this credential

### Data Persistence

Redis is configured with both AOF (append-only file) and periodic RDB snapshots:
- `appendonly yes` — every write is logged, minimal data loss on crash
- `save 900 1` and `save 300 10` — periodic snapshots for faster recovery
- `maxmemory 512mb` with `allkeys-lru` eviction — older chat sessions are evicted when memory is full

Data is stored in `./redis/data/` and persists across container restarts.

### Monitoring Redis

```bash
# Check Redis is responding
podman exec n8n-redis redis-cli -a "$(grep REDIS_PASSWORD .env | cut -d= -f2)" ping

# Check memory usage
podman exec n8n-redis redis-cli -a "$(grep REDIS_PASSWORD .env | cut -d= -f2)" info memory

# List all chat session keys
podman exec n8n-redis redis-cli -a "$(grep REDIS_PASSWORD .env | cut -d= -f2)" keys "*"

# Monitor live commands (Ctrl+C to stop)
podman exec n8n-redis redis-cli -a "$(grep REDIS_PASSWORD .env | cut -d= -f2)" monitor
```

---

## Docling Serve — Document Conversion API

### Why Docling Serve (not Docling library)?

You need **Docling Serve** (not the raw Docling Python library) because:
- It exposes Docling as a **REST API** — perfect for calling from n8n HTTP Request nodes
- It handles async document processing with task queuing
- It includes a Swagger UI at `/docs` and a web UI at `/ui` for testing
- The container comes with all default models pre-baked — no Python environment setup needed
- It supports both synchronous and asynchronous conversion endpoints

### Container Image

We use `quay.io/docling-project/docling-serve-cpu:latest` — the CPU-only variant. Since the t3.xlarge has no GPU, this image excludes CUDA dependencies and is smaller (~4 GB vs ~8 GB for GPU images).

### Pre-bundled Models (in the container image)

These models are included in the container image and require no download:
- **DocLayNet layout model** — RT-DETR based layout analysis
- **TableFormer** — table structure recognition (fast + accurate modes)
- **Picture classifier** — DocumentFigureClassifier v2.0 (ViT)
- **Code & formula extractor** — CodeFormulaV2
- **RapidOCR** — fast CPU-friendly OCR engine

### Additional VLM Models (downloaded by `download-models.sh`)

These are small VLMs that run on CPU without GPU:

| Model | Size | Purpose | CPU Speed |
|-------|------|---------|-----------|
| **Granite-Docling-258M** ⭐ | 258M params | Full-page → DocTags conversion | ~20-30s/page |
| **SmolDocling-256M** | 256M params | Full-page → DocTags conversion | ~20-30s/page |
| **SmolVLM-256M-Instruct** | 256M params | Picture description | ~5-10s/image |

> All three models are tiny (256M parameters) and designed to run on CPU. They provide OCR-like document understanding via vision-language model inference. For most workflows, the **standard pipeline** (layout + table + RapidOCR) is fastest and sufficient. Use VLMs only when you need semantic understanding of document content.

### Using Docling from n8n

**File upload conversion:**
```
HTTP Request node:
  Method: POST
  URL: http://n8n-docling:5001/v1/convert/file
  Content-Type: multipart/form-data
  Body: file = {{ $binary.data }}
```

**URL-based conversion:**
```
HTTP Request node:
  Method: POST
  URL: http://n8n-docling:5001/v1/convert/source
  Content-Type: application/json
  Body: {
    "sources": [{"kind": "http", "url": "https://example.com/document.pdf"}]
  }
```

**Async conversion (for large documents):**
```
Step 1: POST http://n8n-docling:5001/v1/convert/file/async → returns task_id
Step 2: GET  http://n8n-docling:5001/v1/status/poll/{task_id}?wait=30
```

### Monitoring Docling

```bash
# Check health
curl http://localhost:5001/health

# View Swagger API docs
# Open in browser: http://<server-ip>:5001/docs

# Check container logs
podman-compose logs -f docling

# Check model cache size
du -sh /opt/n8n-production/docling/hf-cache/
du -sh /opt/n8n-production/docling/models/
```

---

## Update Workflow

A systemd timer (`n8n-check-updates.timer`) runs `check-updates.sh` daily. The script
pulls the latest image tags, compares them against the running containers, and logs
results to the systemd journal. It never auto-updates — you apply updates manually.

```bash
# Check for available updates (view last check results)
journalctl -u n8n-check-updates.service --since today

# Run update check on demand
sudo systemctl start n8n-check-updates.service

# Timer status
systemctl status n8n-check-updates.timer

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

# Update Docling Serve
podman-compose pull docling
podman-compose up -d docling
# Re-download models if needed (new image may have new defaults)
./docling/download-models.sh
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
podman-compose logs -f redis
podman-compose logs -f docling

# PostgreSQL connections
podman exec n8n-postgres psql -U n8n -d n8n \
  -c "SELECT count(*) FROM pg_stat_activity;"

# Redis memory and keys
podman exec n8n-redis redis-cli -a "$(grep REDIS_PASSWORD .env | cut -d= -f2)" info memory

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

## Troubleshooting

### n8n crashes with `EACCES: permission denied, open '/home/node/.n8n/config'`

The n8n container runs as user `node` (UID 1000). If the host directory `./n8n/data`
is owned by root or another user, n8n cannot write its config file.

**Fix for existing deployments:**
```bash
sudo chown -R 1000:1000 ./n8n/data
```

Then restart n8n:
```bash
podman-compose restart n8n
```

The `deploy.sh` script handles this automatically for fresh deployments.

### Container Name Conflicts During Restart

**Symptom:**
```
Error: creating container storage: the container name "n8n-postgres" is already in use
Error: creating container storage: the container name "n8n-redis" is already in use
```

**Root Cause:**

This error occurs when you run `podman-compose up -d <service>` and the target service has dependencies (defined in `depends_on`) whose containers exist in a stopped state. Podman-compose tries to create the entire dependency tree, but Podman refuses to create containers with names that already exist, even if they're stopped.

**Why this differs from Docker:**
Docker Compose automatically reuses stopped containers with the same name. Podman requires explicit cleanup or the `--replace` flag (not available in podman-compose).

**Affected workflows:**
- Updating a single service: `podman-compose pull n8n && podman-compose up -d n8n`
- Restarting after manual stop: `podman stop n8n-runners && podman-compose up -d n8n-runners`
- Troubleshooting individual services

**Prevention:**

**1. Use systemd for orchestrated restarts (safest):**
```bash
sudo systemctl restart n8n-stack.service
```
The systemd service now includes automatic cleanup of stopped containers before starting.

**2. Use the safe restart script:**
```bash
cd /opt/n8n-production
./restart-service.sh n8n-runners    # Restart specific service
./restart-service.sh all            # Restart all services
```

**3. Use down/up cycle (removes all containers):**
```bash
cd /opt/n8n-production
podman-compose down --timeout 60
podman-compose up -d
```

**Manual Fix:**

If you encounter this error, clean up stopped containers:

```bash
# Check container states
podman ps -a | grep n8n

# Remove specific stopped container
podman rm n8n-postgres

# Or remove all stopped n8n containers
podman ps -a --filter "name=n8n-" --filter "status=exited" --format "{{.Names}}" | xargs -r podman rm

# Then restart
podman-compose up -d
```

**Update workflow (recommended):**

When updating a service, use this sequence:
```bash
cd /opt/n8n-production

# Pull new image
podman-compose pull n8n

# Stop and remove container explicitly
podman stop n8n
podman rm n8n

# Recreate with new image
podman-compose up -d n8n

# Or use the restart script
./restart-service.sh n8n
```
