# E2B on OCI vs AWS - Comprehensive Comparison

**Date**: November 14, 2025  
**Status**: OCI implementation automates Consul/Nomad bootstrap (running as root with raw_exec enabled and ACLs disabled). Orchestrator, API, client-proxy, and template-manager now build templates and snapshots end-to-end on OCI using the Local artifact store. Sandbox CRUD + exec flows are validated via the local snapshot cache, but AWS remains the production reference.

---

## Executive Summary

The OCI implementation (terraform-base) is a **minimal infrastructure foundation** compared to the AWS reference implementation. The core application code (packages/) is largely identical, but significant components are missing or incomplete in the OCI version.

---

## 1. TERRAFORM INFRASTRUCTURE

### terraform-base/ (OCI) vs infra-iac/terraform/ (AWS)

| Component | OCI (~660 lines) | AWS (1,218 lines) | Status |
|-----------|----------------|-------------------|---------|
| **Networking** | ✅ VCN, public/private subnets, IGW, NAT GW, Service GW, LB subnet, route tables, comprehensive security lists | ✅ VPC (pre-existing) | **OCI: Complete** |
| **Compute** | ✅ Bastion only (multi-AD ready) | ✅ Auto-scaling groups (Server, Client, API, Build) | OCI: Missing clusters |
| **Load Balancer** | ✅ LB subnet prepared | ✅ ALB with SSL, target groups, listeners | **OCI: Missing LB resource** |
| **Object Storage** | ✅ 8 OCI Object Storage buckets (mirrors AWS naming, namespace auto-detected) | ✅ 8 S3 buckets (Terraform hard-coded names) | **OCI: Complete** |
| **Secrets Management** | ❌ None | ✅ AWS Secrets Manager (4 secrets) | **Missing** |
| **IAM/Policies** | ✅ Basic (bastion) | ✅ Comprehensive (all services) | OCI: Incomplete |
| **Database** | ✅ Managed PostgreSQL (Terraform) + Redis (managed cache) | ✅ RDS configuration (via CloudFormation) | **OCI: Hard-coded password, TLS-only Redis** |
| **Monitoring** | ❌ None | ✅ CloudWatch logs | **Missing** |

### OCI Missing Components (Detailed)

#### A. Auto-Scaling Groups
AWS has 4 distinct cluster types:
- **Server cluster**: 3 nodes (Nomad/Consul servers)
- **Client cluster**: 1-5 nodes (Firecracker workloads)
- **API cluster**: 1 node (E2B API, Client Proxy)
- **Build cluster**: 0 nodes (template building)

OCI has: **Server, API, and client pools bootstrap Consul/Nomad automatically via user-data (ACLs disabled, agents run as root, raw_exec enabled, Firecracker prep baked in)**

#### B. Networking (NOW COMPLETE ✅)
**OCI networking now includes:**
- ✅ Public subnet (10.0.1.0/24) with Internet Gateway
- ✅ Private subnet (10.0.2.0/24) with NAT Gateway
- ✅ Public Load Balancer subnet (10.0.3.0/24) - conditional
- ✅ NAT Gateway for private subnet internet access
- ✅ Service Gateway for OCI services (Object Storage, etc.)
- ✅ Comprehensive security lists for E2B services:
  - SSH, HTTP/HTTPS
  - PostgreSQL (5432), Redis (6379)
  - Nomad (4646-4648), Consul (8300-8302, 8500, 8600)
  - Orchestrator (50051), Template Manager (50052)
  - Client Proxy (3001-3002), E2B API (50001)
  - ICMP for path MTU discovery
- ✅ Multi-AD support in locals (ready for cluster deployment)
- ✅ Terraform filters Ubuntu images by shape and architecture, preventing ARM images from being selected for x86 bastion shapes.

**Still missing:** Load balancer resource itself (backend sets, listeners, SSL config)

#### C. Object Storage Buckets (NOW COMPLETE ✅)
AWS creates 8 buckets:
1. `loki-storage` - Logs
2. `envs-docker-context` - Environment contexts
3. `cluster-setup` - Setup scripts
4. `fc-kernels` - Firecracker kernels
5. `fc-versions` - Firecracker binaries
6. `fc-env-pipeline` - Build artifacts
7. `fc-template` - Template storage
8. `docker-contexts` - Docker contexts

OCI now mirrors these buckets via the `modules/object_storage_bucket` Terraform module with matching display names. Buckets are provisioned in Object Storage under the target compartment; namespace is auto-discovered (AWS stack also hard-codes account-specific bucket names). **Status: complete (IAM policies/lifecycle rules still to be aligned).**

#### D. Secrets Management
AWS Secrets Manager stores:
1. Consul ACL token
2. Nomad ACL token
3. Consul gossip encryption key
4. Consul DNS request token

OCI has: **None** - POC uses plaintext env vars

#### E. Load Balancer Resource
AWS ALB configuration:
- Public-facing HTTPS (port 443)
- SSL certificate from ACM
- 4 target groups (nomad-server, e2b-api, client-proxy, docker-proxy)
- Path-based routing by subdomain

OCI has: **LB subnet prepared** - Missing actual load balancer resource (backend sets, listeners, SSL)

---

## 2. PACKER CONFIGURATION

### packer/ (Both)

| Aspect | OCI | AWS | Notes |
|--------|-----|-----|-------|
| **Directory** | `/packer/` | `/infra-iac/packer/` | Different location |
| **Base image** | Ubuntu 22.04 (OCI images) | Ubuntu 22.04 (AWS AMI) | Same OS |
| **Setup scripts** | ✅ Consul, Nomad, supervisord | ✅ Same | Identical |
| **Docker config** | ✅ daemon.json | ✅ Same | Identical |
| **GC config** | ❌ Missing | ✅ gc-ops.config.yaml | **AWS has garbage collection config** |

**Status**: Nearly identical, but OCI missing garbage collection config. Base image build path (`bastion-init.sh` → `packer build`) completes successfully.

---

## 3. PACKAGES (APPLICATION CODE)

### packages/ (Both)

| Package | OCI | AWS | Differences |
|---------|-----|-----|-------------|
| **api/** | ✅ Identical | ✅ Full | Same code |
| **client-proxy/** | ✅ Identical | ✅ Full | Same code (OCI defaults to the in-memory sandbox catalog via `USE_CATALOG_RESOLUTION=true`; Redis becomes optional) |
| **db/** | ✅ Identical | ✅ Full | Same code |
| **envd/** | ✅ Identical | ✅ Full | Same code |
| **orchestrator/** | ✅ Modified (12 changes) | ✅ Original | **OCI has POC patches** |
| **shared/** | ✅ Identical | ✅ Full | Same code |
| **docker-reverse-proxy/** | ❌ **MISSING** | ✅ Full service | **Critical missing service** |
| **fc-kernels/** | ❌ **MISSING** | ✅ Build scripts | **Missing kernel build pipeline** |
| **fc-versions/** | ❌ **MISSING** | ✅ Build scripts | **Missing Firecracker build pipeline** |

### Key Missing Services

#### A. docker-reverse-proxy (OCI Missing)
**Purpose**: Reverse proxy for Docker registry access  
**Location (AWS)**: `packages/docker-reverse-proxy/`
- Dockerfile
- Go source (auth, cache, handlers, utils)
- Terraform outputs
- Makefile

**Impact**: Cannot proxy Docker pulls from sandboxes

#### B. fc-kernels (OCI Missing)
**Purpose**: Build custom Firecracker kernels  
**Location (AWS)**: `packages/fc-kernels/`
- `build.sh` - Kernel compilation script
- `configs/6.1.102.config` - Kernel config
- `kernel_versions.txt` - Version manifest
- `upload.sh` - S3 upload

**Impact**: OCI uses pre-built kernels (manual download)

#### C. fc-versions (OCI Missing)
**Purpose**: Build/manage Firecracker binary versions  
**Location (AWS)**: `packages/fc-versions/`
- `build.sh` - Firecracker compilation
- `firecracker_versions.txt` - Version manifest
- `upload.sh` - S3 upload

**Impact**: OCI uses pre-built Firecracker (manual install)

### Orchestrator Code Changes (12 Modifications in OCI)

According to POC_SUMMARY.md, the OCI version has 12 code changes:

**OCI-Specific (should keep)**:
1. `network_linux.go` - iptables syntax (`--to-source/--to-destination`)
2. `process.go` - Added `root=/dev/vda rootfstype=ext4`
3. `sync.go` - Skip clock sync if `/dev/ptp0` missing
4. `grpcserver/server.go` - Force IPv4 binding

**POC Workarounds (should revert)**:
5. `sandbox_features.go` - Made commit hash optional
6. `node.go` - Filter nodes by `NodeClass="client"`
7. `drive.go` - Changed `IsReadOnly` from `bool` to `*bool`
8. `client_linux.go` - Commented out HugePages
9. `sandboxes.go` - Added CreateSandbox path, set `KernelLogs: false`
10. `sandbox.go` - Use NBDProvider when `rootfsCachePath=""`
11. `create_instance.go` - Added debug logging
12. Nomad configs - Changed ports (5008→50051, 5009→50052)

---

## 4. NOMAD JOB DEFINITIONS

### nomad/ (OCI) vs nomad/origin/ (AWS)

| Service | OCI | AWS | Notes |
|---------|-----|-----|-------|
| **api.hcl** | ✅ Present | ✅ Present | Similar |
| **orchestrator.hcl** | ✅ Present | ✅ Present | OCI uses different ports |
| **client-proxy.hcl** | ✅ Present | ❌ (via api.hcl) | Separate in OCI |
| **template-manager.hcl** | ✅ Present | ✅ Present | Similar |
| **docker-reverse-proxy.hcl** | ❌ **MISSING** | ✅ Present | **Missing service** |
| **edge.hcl** | ❌ **MISSING** | ✅ Present | **Missing edge service** |
| **loki.hcl** | ❌ **MISSING** | ✅ Present | **Missing log aggregation** |
| **logs-collector.hcl** | ❌ **MISSING** | ✅ Present | **Missing log collector** |
| **otel-collector.hcl** | ❌ **MISSING** | ✅ Present | **Missing observability** |
| **redis.hcl** | ❌ **MISSING** | ✅ Present | **AWS deploys Redis in Nomad** |

**Key Differences**:
- OCI has 4 Nomad jobs, AWS has 9
- AWS has comprehensive observability stack (Loki, OTel)
- AWS deploys Redis as Nomad job (OCI uses managed service)
- OCI uses different port numbers

### Port Number Differences

| Service | AWS Port | OCI Port | Reason |
|---------|----------|----------|--------|
| Orchestrator | 5008 | 50051 | Arbitrary POC change |
| Template Manager | 5009 | 50052 | Arbitrary POC change |
| API | 50001 | 80 | POC simplification |

---

## 5. DEPLOYMENT SCRIPTS

### OCI (Root Directory)

All deployment scripts excluded from git (*.sh in .gitignore):
- `deploy-poc.sh` - Main POC deployment
- `setup-firecracker.sh` - Install Firecracker + kernel
- `setup-nomad-consul.sh` - Install Nomad/Consul
- `start-cluster.sh` - Start services
- `deploy-services.sh` - Deploy Nomad jobs
- `deploy-template-manager.sh` - Deploy template-manager
- `create-template.sh` - Create template via API
- `disable-firewalls.sh` - Flush iptables (workaround)
- `start-tunnel.sh` - SSH tunnel for access
- `validate-e2e.sh` - E2E validation suite

### AWS (infra-iac/)

Structured deployment:
- `infra-iac/init.sh` - Main initialization
- `infra-iac/destroy.sh` - Cleanup
- `infra-iac/terraform/prepare.sh` - Terraform prep
- `infra-iac/terraform/start.sh` - Start deployment
- `infra-iac/db/init-db.sh` - Database setup
- `nomad/deploy.sh` - Nomad job deployment
- `nomad/prepare.sh` - Nomad preparation
- `packages/build.sh` - Build all packages
- `packages/upload.sh` - Upload to S3

**Key Difference**: AWS has production-grade deployment pipeline; OCI has POC scripts

---

## 6. CONFIGURATION FILES

### Environment Files

**OCI**: Has .env.example files
- `packages/api.env.example`
- `packages/orchestrator.env.example`
- `packages/client-proxy.env.example`
- `packages/template-manager.env.example`

**AWS**: No .env.example files (uses different config approach)

### CloudFormation

**OCI**: None  
**AWS**: `e2b-setup-env.yml` - Complete infrastructure stack

---

## 7. DATABASE SETUP

### Database Scripts

| Location | OCI | AWS |
|----------|-----|-----|
| **Init script** | `db/init-db.sh` | `infra-iac/db/init-db.sh` |
| **Migration SQL** | `db/migration.sql` | `packages/db/migrations/` (44 files) |
| **Seed data** | `db/seed-db.sql` | (via init script) |

**Key Difference**: 
- OCI has simplified single-file migrations. The managed PostgreSQL instance is provisioned via Terraform with a **hard-coded admin password (`E2bP0cPostgres!2025`)** for the POC; no database schema or user rotation is automated yet.
- AWS has comprehensive migration system with 44 files

### Redis Configuration
- **OCI**: Uses managed Redis (OCI Cache) with TLS enforced; `redis-cli` must specify `--tls` and `--cacert`. No AUTH string is provided by the service (connections rely on VCN/NSG isolation). PostgreSQL requires the post-apply `db/init-db.sh` script to seed schema/data.
- **AWS**: Uses ElastiCache Redis (TLS optional) with authentication token via Secrets Manager.

---

## 8. TESTING & EXAMPLES

### Test Use Cases

**OCI**: 
- `examples/demo_execution.py`
- `examples/demo_lifecycle.sh`
- `examples/README.md`

**AWS**:
- `test_use_case/test_code_interpreter.py`
- `test_use_case/test_e2b_desktop.py`
- `test_use_case/test_e2b_sdk.py`
- `test_use_case/Dockerfile/` (4 example Dockerfiles)

**Status**: AWS has more comprehensive testing suite

---

## 9. DOCUMENTATION

### README Files

**OCI**: 
- ✅ Root-level README.md runbook (Terraform → deploy-poc.sh → validation)
- ✅ POC_SUMMARY.md (detailed implementation notes)
- ✅ LICENSE

**AWS**:
- ✅ Comprehensive README.md (deployment guide)
- ✅ CONTRIBUTING.md
- ✅ CODE_OF_CONDUCT.md
- ✅ NOTICE
- ✅ LICENSE

**Status**: AWS still has the broader documentation set, but OCI now ships a reproducible deployment runbook.


---

## 10. MISSING OCI PROVIDERS (Code Implementation)

### A. OCI Object Storage Provider
**File needed**: `packages/shared/pkg/storage/storage_oci.go`

**What exists**:
- ✅ `storage_aws.go` (155 lines)
- ✅ `storage_google.go` (200+ lines)
- ✅ `storage_fs.go` (97 lines)

**What's missing**: OCI implementation (~200 lines needed)

### B. OCI Container Registry (OCIR) Provider
**File needed**: `packages/shared/pkg/artifacts-registry/registry_oci.go`

**What exists**:
- ✅ `registry_aws.go` (ECR)
- ✅ `registry_gcp.go` (Artifact Registry)
- ✅ `registry_local.go` (POC only)

**What's missing**: OCIR implementation (~150 lines + credential helper)

---

## 11. ARCHITECTURAL DIFFERENCES

### Infrastructure Pattern

**AWS**:
- Full auto-scaling groups (server, client, api, build)
- Load balancer with SSL termination
- Secrets Manager for credentials
- S3 for all artifacts
- CloudWatch for monitoring
- Multi-AZ deployment

**OCI**:
- Single bastion instance only (in Terraform)
- Manual instance creation (in POC)
- No load balancer
- No secrets management (plaintext env vars)
- Local filesystem storage
- No monitoring/logging
- Single AD deployment

### Service Discovery

**AWS**:
- Auto-scaling groups
- Target groups
- ALB path-based routing
- Consul service discovery

**OCI**:
- Static IPs
- No auto-scaling
- Direct instance access
- Consul service discovery (same as AWS)
- Artifacts/binaries delivered from the repo (`artifacts/bin/*`); Object Storage/OCIR integration pending

### Storage Strategy

**AWS**: Cloud-native
- S3 for templates, kernels, builds
- RDS for database
- ElastiCache for Redis

**OCI**: Hybrid (POC)
- Local filesystem for templates
- OCI PostgreSQL (managed)
- OCI Cache (managed, TLS required)

---

## 12. SUMMARY TABLE: WHAT'S MISSING IN OCI

| Category | Component | Status | Effort |
|----------|-----------|--------|--------|
| **Infrastructure** | Networking (VCN, subnets, gateways, security) | ✅ **Complete** | Done |
| **Infrastructure** | Auto-scaling groups | ❌ Missing | High (Terraform) |
| **Infrastructure** | Load balancer resource | ⚠️ Subnet ready | Medium (Terraform) |
| **Infrastructure** | Object Storage buckets | ✅ Implemented (matches AWS naming; namespace auto-detected) | Medium (policies/lifecycle still pending) |
| **Infrastructure** | Secrets management | ❌ Missing | Medium (OCI Vault) |
| **Infrastructure** | Monitoring/logging | ❌ Missing | Medium (Terraform) |
| **Code** | OCI Object Storage provider | ❌ Missing | Medium (~200 lines) |
| **Code** | OCIR provider | ❌ Missing | Medium (~150 lines) |
| **Services** | docker-reverse-proxy | ❌ Missing | Low (copy from AWS) |
| **Services** | Loki log aggregation | ❌ Missing | Low (Nomad job) |
| **Services** | OTel collector | ❌ Missing | Low (Nomad job) |
| **Services** | Logs collector | ❌ Missing | Low (Nomad job) |
| **Services** | Edge service | ❌ Missing | Low (Nomad job) |
| **Build** | fc-kernels pipeline | ❌ Missing | Low (copy + modify) |
| **Build** | fc-versions pipeline | ❌ Missing | Low (copy + modify) |
| **Deployment** | Production scripts | ⚠️ Terraform + `deploy-poc.sh` + `deploy-services.sh` (manual DB seed) | Medium (automation) |
| **Deployment** | CloudFormation equiv | ❌ Missing | High (OCI Resource Manager) |
| **Code Changes** | 12 orchestrator patches | ⚠️ POC-level | Medium (review/clean) |
| **Documentation** | Main README | ❌ Missing | Low (adapt from AWS) |
| **Testing** | Comprehensive tests | ⚠️ Limited | Low (copy from AWS) |

---

## 13. PRODUCTION READINESS COMPARISON

### AWS: ✅ Production-Ready
- ✅ Complete infrastructure as code
- ✅ Auto-scaling and HA
- ✅ Load balancing with SSL
- ✅ Comprehensive secrets management
- ✅ Monitoring and logging
- ✅ All services implemented
- ✅ Full documentation
- ✅ Testing suite

### OCI: ⚠️ POC-Level (Need M2)
- ✅ Core services work (API, Orchestrator, Template Manager)
- ✅ Sandbox lifecycle functional
- ✅ Database integration working
- ✅ Firecracker VMs boot successfully
- ❌ No auto-scaling
- ❌ No load balancer
- ❌ No secrets management
- ❌ Missing observability stack
- ❌ Missing OCI-specific providers
- ❌ 12 code changes need review
- ✅ Template building functional (envd/service/systemd parity with AWS achieved; snapshot artifacts produced locally)

---

## 14. ESTIMATED EFFORT TO REACH PRODUCTION

| Task | Complexity | Est. Lines | Priority |
|------|------------|-----------|----------|
| OCI Object Storage provider | Medium | ~200 | P0 (Critical) |
| OCIR provider + auth | Medium | ~150+helper | P0 (Critical) |
| Expand Terraform (terraform-base) | High | ~550 | P0 (Critical) |
| Load balancer + SSL | Medium | ~150 | P0 (Critical) |
| Secrets management (Vault) | Medium | ~100 | P0 (Critical) |
| Review 12 code changes | High | Variable | P0 (Critical) |
| Production Nomad jobs | Medium | ~200 | P1 (Important) |
| Add missing Nomad services | Low | ~500 | P1 (Important) |
| docker-reverse-proxy port | Low | Copy | P1 (Important) |
| fc-kernels build pipeline | Low | Copy+modify | P2 (Nice to have) |
| fc-versions build pipeline | Low | Copy+modify | P2 (Nice to have) |
| Production deployment scripts | Medium | ~500 | P1 (Important) |
| Documentation | Low | ~300 | P2 (Nice to have) |
| Testing suite expansion | Low | Copy+modify | P2 (Nice to have) |

**Total Estimated Effort**: ~2,800 lines of new code + infrastructure expansion + code review

---

## 15. KEY TAKEAWAYS

### What OCI Has (Working in POC)
1. ✅ Core application packages (api, orchestrator, template-manager, client-proxy)
2. ✅ Database integration (PostgreSQL, Redis with TLS)
   - PostgreSQL admin password is hard-coded (`E2bP0cPostgres!2025`) via Terraform outputs for now
   - Redis has no username/password; connectivity relies on VCN/NSG isolation
3. ✅ Nomad/Consul clustering (ACLs disabled; validated across server, API, and client pools)
4. ✅ Firecracker VM execution and snapshotting (memfile staging fixed; `/snapshot/create` now succeeds)
5. ✅ Sandbox lifecycle (create/delete) and template builds (envd service boots under systemd inside the guest)
6. ✅ Hello-world sandbox execution parity (client-proxy catalog + exec APIs wired end-to-end)
7. ✅ Basic networking (VCN, subnets)
8. ✅ Basic Packer configuration
9. ✅ Root README documents Terraform → deploy-poc → testing flow

### What OCI Needs for Production
1. ❌ Complete Terraform infrastructure (~800 lines vs 247)
2. ❌ OCI Object Storage provider implementation
3. ❌ OCIR registry provider implementation
4. ❌ Load balancer with SSL termination
5. ❌ Secrets management (OCI Vault)
6. ❌ Observability stack (Loki, OTel, logs-collector) — deferred to later milestone
7. ❌ docker-reverse-proxy service
8. ❌ Auto-scaling groups
9. ❌ Production deployment pipeline
10. ❌ Code review and cleanup of 12 POC patches
11. ❌ fc-kernels and fc-versions build pipelines
12. ❌ Comprehensive documentation

### Critical Path to Production (M2)
1. **Fix template building** - envd/systemd configuration ✅ complete (OCI rootfs now matches AWS behaviour)
2. **Implement OCI providers** - Object Storage + OCIR
3. **Expand Terraform** - Auto-scaling, LB, secrets, monitoring
4. **Review code changes** - Keep OCI-specific, revert POC hacks
5. **Production Nomad jobs** - Add missing services, fix configs (observability still out of scope)
6. **Deployment automation** - Production-grade scripts & artifact delivery (replace manual `deploy-poc.sh`, add Object Storage/OCIR)

---

**Document Created**: November 7, 2025  
**Based on**: 
- OCI: `/Users/chezhzha/work/e2b/e2b-on-oci`
- AWS: `/Users/chezhzha/work/e2b/sample-e2b-on-aws`
- Reference: POC_SUMMARY.md

