# E2B on OCI - Debugging Guide

Quick reference for diagnosing common issues in the E2B on OCI deployment.
> Scope: This guide is for debugging validation script failures and dev/test issues in E2B on OCI.
> In normal operation, the validation script should complete without errors. Use this guide when it
> reports failures.
> 
## Prerequisites

```bash
# Source environment variables
source deploy.env
source api-creds.env

# SSH helper functions (from validate-api.sh)
SSH_OPTS=(-i "${SSH_KEY:-$HOME/.ssh/e2b_id_rsa}" -o ProxyCommand="ssh -i ${SSH_KEY:-$HOME/.ssh/e2b_id_rsa} -W %h:%p ubuntu@${BASTION_HOST}" -o StrictHostKeyChecking=no)
```

## Service Status Checks

### Check Nomad Jobs
```bash
# List all jobs
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "nomad job status"

# Check specific service
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "nomad job status orchestrator"
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "nomad job status template-manager"
ssh "${SSH_OPTS[@]}" ubuntu@${API_POOL_PRIVATE:-${API_POOL_PUBLIC}} "nomad job status api"
```

### Check Node Status
```bash
# List Nomad nodes
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "nomad node status"

# Check if nodes are ready
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "nomad node status | grep -E 'ready|drain|down'"
```

## Template Manager Failures

### Check Template Manager Logs
```bash
# Get latest allocation ID
ALLOC_ID=$(ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "nomad job status template-manager 2>&1 | grep -A 5 Allocations | tail -1 | awk '{print \$1}'")

# View recent logs
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "nomad alloc logs ${ALLOC_ID} template-manager 2>&1 | tail -100"

# Search for errors
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "nomad alloc logs ${ALLOC_ID} template-manager 2>&1 | grep -E 'error|Error|ERROR|failed|Failed|FAILED' | tail -30"
```

### Check Template Build Status
```bash
# Via API
API_BASE="http://127.0.0.1:50001"
ssh "${SSH_OPTS[@]}" ubuntu@${API_POOL_PRIVATE:-${API_POOL_PUBLIC}} "curl -sS -H 'X-API-Key: ${TEAM_API_KEY}' -H 'Authorization: Bearer ${ADMIN_API_TOKEN}' ${API_BASE}/templates/${TEMPLATE_ID}/builds/${BUILD_ID}/status | jq '.'"
```

### Common Template Manager Issues

#### 1. Template Build Fails: "provision script failed"
**Symptoms:**
- Template build status: `error`
- Error message: "provision script failed with exit status: 1"

**Debug:**
```bash
# Check template-manager logs for provision script output
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "nomad alloc logs ${ALLOC_ID} template-manager 2>&1 | grep -A 20 'provision script' | tail -30"

# Check if rootfs file exists
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "sudo ls -lh /tmp/build-templates/${BUILD_ID}/rootfs.ext4.build* 2>/dev/null"
```

**Common Causes:**
- Provision script syntax error
- Package installation failures
- Disk space issues

#### 2. Template Build Fails: "no space left on device"
**Symptoms:**
- Docker build fails
- Rootfs extraction fails
- Error: "no space left on device"

**Debug:**
```bash
# Check disk usage
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "df -h /"

# Check large directories
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "sudo du -sh /tmp/build-templates /var/e2b/templates /orchestrator/sandbox 2>/dev/null | sort -h"

# Clean up old builds
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "sudo find /tmp/build-templates -mindepth 1 -maxdepth 1 -type d -mtime +1 -exec sudo rm -rf {} \;"
```

## Sandbox Creation Failures

### Check Orchestrator Logs
```bash
# Get orchestrator allocation ID
ALLOC_ID=$(ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "nomad job status orchestrator 2>&1 | grep -A 5 Allocations | tail -1 | awk '{print \$1}'")

# View recent logs
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "nomad alloc logs ${ALLOC_ID} orchestrator 2>&1 | tail -100"

# Search for CreateSandbox errors
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "nomad alloc logs ${ALLOC_ID} orchestrator 2>&1 | grep -E 'CreateSandbox|Creating sandbox|SandboxService/Create|error|Error|failed|Failed' | tail -30"
```

### Check Allocation Status
```bash
# Check why allocation failed
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "nomad alloc status ${ALLOC_ID} 2>&1 | grep -A 30 'Task Events'"
```

### Common Sandbox Creation Issues

#### 1. "Failed to get node to place sandbox on"
**Symptoms:**
- API returns: `{"code": 500, "message": "Failed to get node to place sandbox on."}`
- CreateSandbox API call fails immediately

**Debug:**
```bash
# Check if orchestrator is running
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "nomad job status orchestrator | grep -E 'Status|Running|Failed'"

# Check orchestrator allocation status
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "nomad alloc status -short 2>&1 | grep orchestrator"

# Check if orchestrator is registered in Nomad
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "nomad node status | grep -E 'ready|drain|down'"
```

**Common Causes:**
- Orchestrator allocation failed (check exit code)
- Orchestrator not registered in Nomad
- Lock file preventing startup (see below)

#### 2. Orchestrator Exits Immediately (Exit Code 1)
**Symptoms:**
- Orchestrator allocation status: `failed`
- Exit Code: 1
- Task restarts multiple times then stops

**Debug:**
```bash
# Check startup logs
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "nomad alloc logs ${ALLOC_ID} orchestrator 2>&1 | grep -E 'Starting|Orchestrator was already started|lock|Lock|fatal|Fatal' | tail -20"

# Check for lock file
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "sudo test -f /opt/e2b/runtime/orchestrator.lock && echo 'LOCK FILE EXISTS' || echo 'NO LOCK FILE'"

# Check if port is in use
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "sudo lsof -i :5008 2>/dev/null || echo 'PORT 5008 NOT IN USE'"
```

**Common Causes:**
- Stale lock file: `/opt/e2b/runtime/orchestrator.lock`
- Port 5008 already in use
- Binary missing or permissions issue

**Fix:**
```bash
# Remove stale lock file
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "sudo rm -f /opt/e2b/runtime/orchestrator.lock"

# Restart orchestrator
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "nomad job restart orchestrator"
```

#### 3. "fc process exited prematurely"
**Symptoms:**
- Sandbox creation starts but Firecracker exits before envd starts
- Logs show: "fc process exited prematurely"
- Exit code: 0 (clean exit, but too early)

**Debug:**
```bash
# Check Firecracker logs
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "nomad alloc logs ${ALLOC_ID} orchestrator 2>&1 | grep -E 'fc process|Firecracker|Vmm is stopping|path_on_host' | tail -20"

# Check COW cache file
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "sudo ls -lh /orchestrator/sandbox/*.cow 2>/dev/null | tail -3"
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "sudo file /orchestrator/sandbox/*.cow 2>/dev/null | head -1"

# Check if cache population completed
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "nomad alloc logs ${ALLOC_ID} orchestrator 2>&1 | grep -E 'Populating DirectProvider|DirectProvider cache populated|bytesCopied' | tail -5"
```

**Common Causes:**
- Empty COW cache file (cache population didn't complete)
- Invalid ext4 filesystem in COW file
- Firecracker can't access rootfs path (namespace/symlink issues)

#### 4. Cache Population Timeout
**Symptoms:**
- CreateSandbox API call times out
- Logs show "Populating DirectProvider cache" but no completion
- COW file exists but may be incomplete

**Debug:**
```bash
# Check cache population progress
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "nomad alloc logs ${ALLOC_ID} orchestrator 2>&1 | grep -E 'Populating DirectProvider|DirectProvider cache populated|bytesCopied' | tail -5"

# Check COW file size vs expected
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "sudo ls -lh /orchestrator/sandbox/*.cow 2>/dev/null"
```

**Common Causes:**
- Very large rootfs files (>10GB) taking longer than timeout
- Slow disk I/O
- Network issues reading from template storage

## API Issues

### Check API Logs
```bash
# Get API allocation ID
ALLOC_ID=$(ssh "${SSH_OPTS[@]}" ubuntu@${API_POOL_PRIVATE:-${API_POOL_PUBLIC}} "nomad job status api 2>&1 | grep -A 5 Allocations | tail -1 | awk '{print \$1}'")

# View recent logs
ssh "${SSH_OPTS[@]}" ubuntu@${API_POOL_PRIVATE:-${API_POOL_PUBLIC}} "nomad alloc logs ${ALLOC_ID} api 2>&1 | tail -100"
```

### Check API Health
```bash
API_BASE="http://127.0.0.1:50001"
ssh "${SSH_OPTS[@]}" ubuntu@${API_POOL_PRIVATE:-${API_POOL_PUBLIC}} "curl -sS ${API_BASE}/health"
```

## Database Issues

### Check Database Connection
```bash
ssh "${SSH_OPTS[@]}" ubuntu@${API_POOL_PRIVATE:-${API_POOL_PUBLIC}} "PGPASSWORD=${POSTGRES_PASSWORD} psql -h ${POSTGRES_HOST} -p ${POSTGRES_PORT} -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c 'SELECT 1;' 2>&1"
```

### Check Template Status in DB
```bash
ssh "${SSH_OPTS[@]}" ubuntu@${API_POOL_PRIVATE:-${API_POOL_PUBLIC}} "PGPASSWORD=${POSTGRES_PASSWORD} psql -h ${POSTGRES_HOST} -p ${POSTGRES_PORT} -U ${POSTGRES_USER} -d ${POSTGRES_DB} -t -c \"SELECT id, build_count FROM envs WHERE id = '${TEMPLATE_ID}';\" 2>&1"
```

## Network Issues

### Check Network Namespaces
```bash
# List network namespaces
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "sudo ip netns list"

# Check for stale namespaces
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "sudo find /var/run/netns -type l ! -exec test -e {} \; -print"
```

### Clean Up Network Resources
```bash
# Run cleanup script
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "sudo /usr/local/bin/e2b-cleanup-network.sh"
```

## Disk Space Issues

### Check Disk Usage
```bash
# Overall disk usage
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "df -h /"

# Check large directories
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "sudo du -sh /tmp/build-templates /var/e2b/templates /orchestrator/sandbox 2>/dev/null | sort -h"
```

### Clean Up Disk Space
```bash
# Remove old template builds
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "sudo find /tmp/build-templates -mindepth 1 -maxdepth 1 -type d -mtime +1 -exec sudo rm -rf {} \;"

# Remove old COW cache files
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "sudo find /orchestrator/sandbox -name '*.cow' -type f -mtime +1 -delete"

# Remove unused Docker images
ssh "${SSH_OPTS[@]}" ubuntu@${CLIENT_POOL_PRIVATE:-${CLIENT_POOL_PUBLIC}} "sudo docker image prune -f"
```

## Quick Diagnostic Checklist

When debugging a failing service:

1. **Check Nomad job status**
   ```bash
   nomad job status <service-name>
   ```

2. **Check allocation status**
   ```bash
   nomad alloc status <allocation-id>
   ```

3. **View recent logs**
   ```bash
   nomad alloc logs <allocation-id> <task-name> | tail -100
   ```

4. **Search for errors**
   ```bash
   nomad alloc logs <allocation-id> <task-name> | grep -E 'error|Error|ERROR|failed|Failed|FAILED|fatal|Fatal|panic|Panic'
   ```

5. **Check system resources**
   ```bash
   df -h /  # Disk space
   free -h  # Memory
   ```

## Common Error Patterns

| Error Message | Service | Likely Cause | Debug Command |
|--------------|---------|--------------|---------------|
| "Failed to get node to place sandbox on" | API | Orchestrator not running/registered | `nomad job status orchestrator` |
| "Orchestrator was already started" | Orchestrator | Stale lock file | Check `/opt/e2b/runtime/orchestrator.lock` |
| "fc process exited prematurely" | Orchestrator | Empty/invalid COW cache file | Check COW file size and ext4 signature |
| "provision script failed" | Template Manager | Script error or package install failure | Check template-manager logs for script output |
| "no space left on device" | Template Manager | Disk full | `df -h /` and clean up old builds |
| "address already in use" | Any | Port conflict | `lsof -i :<port>` |

## Getting Help

When reporting issues, include:
1. Service name and allocation ID
2. Relevant log excerpts (last 50-100 lines)
3. Error messages
4. Steps to reproduce
5. Recent changes (if any)

