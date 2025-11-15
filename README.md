# E2B on OCI – Deployment Runbook

This runbook documents the standard procedure for deploying the E2B API and supporting services on Oracle Cloud Infrastructure (OCI). Follow the steps below in sequence to provision infrastructure, stage runtime assets, and validate the platform.

## Repository Overview

```
e2b-on-oci/
├── terraform-base/        # Networking, bastion, IAM policies, object storage buckets, managed PostgreSQL/Redis (Stack 1)
├── terraform-cluster/     # Nomad/Consul/API/client pools (Stack 2)
├── packages/              # Source code for API, orchestrator, client-proxy, template-manager, envd, shared libs
├── artifacts/bin/         # Prebuilt Linux AMD64 binaries uploaded by deploy-poc.sh
├── nomad/                 # Nomad job definitions (api.hcl, orchestrator.hcl, client-proxy.hcl, template-manager.hcl)
├── deploy-poc.sh          # Provisioning script that pushes binaries/configs and installs dependencies
├── deploy-services.sh     # Registers Nomad jobs after deploy-poc.sh finishes
├── db/                    # init-db.sh + SQL seeds/migrations for the managed PostgreSQL instance
├── examples/              # Demo scripts for exercising the API/sandbox lifecycle
├── deploy.env.example     # Template for the local deployment config (copy to deploy.env, ignored by git)
└── README.md              # This runbook
```

- **terraform-base** and **terraform-cluster** remain separate stacks so you can iterate on cluster resources without recreating networking/DB resources. Zip each folder to produce `e2b-oci-stack.zip` (base) and `e2b-oci-cluster.zip` (cluster).
- **packages/** mirrors the AWS repo; build binaries with `GOOS=linux GOARCH=amd64` and drop them into `artifacts/bin/` so `deploy-poc.sh` can upload them.
- **deploy-poc.sh** reads `deploy.env`, connects through the bastion, installs dependencies, uploads env files/binaries, and downloads Firecracker assets.
- **terraform-cluster** user-data now enables the `e2b-cleanup-network.timer` on the client pool, which runs every minute to delete idle `ns-*` namespaces and detach orphaned `nbd` devices so template builds never exhaust the slot pool.
- **deploy-services.sh** copies the Nomad job files and runs `nomad job run` for orchestrator, API, client-proxy, and template-manager.
- **db/init-db.sh** seeds the managed PostgreSQL instance (schema + API keys). Run it before API validation.
- **deploy.env.example** documents every value the scripts need (bastion IP, pool IPs, PostgreSQL host, artifacts path). Copy it to `deploy.env` (ignored by git) and fill it in using the OCI Console outputs.

## Quickstart Overview

1. **Package Terraform** – upload the base and cluster stacks to OCI Resource Manager.
2. **Apply Terraform** – provision OCI networking, IAM policies, managed services, and bring up the Nomad/Consul server/API/client pools.
3. **Stage Runtime Artifacts** – copy the prebuilt binaries, kernels, and configuration to the instances.
4. **Register Nomad Jobs** – launch the orchestrator, API, client-proxy, and template-manager.
5. **Initialize PostgreSQL** – load schema and seeds required for the API to authorize requests.
6. **Smoke Test the API** – confirm health endpoints and a template flow from your workstation.

The sections below expand each step in detail.

## Prerequisites

- macOS or Linux workstation with `zip`, `ssh`, and `scp`.
- Access to the OCI tenancy (Resource Manager + Compute).
- OCI command-line configured locally **or** access to the bastion host created by `terraform-base`.
- Service binaries cross-compiled for Linux and staged under `artifacts/bin/`.
- Ability to reach the upstream Firecracker release buckets (used by the provisioning script to fetch kernels and the `firecracker` binary).

### Artifact checklist

Before you run any deployment scripts, confirm the following files exist:

| Component | Expected location | Notes |
|-----------|-------------------|-------|
| `e2b-api` | `artifacts/bin/e2b-api` | Build from `packages/api` using `GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o ../../artifacts/bin/e2b-api .` |
| `client-proxy` | `artifacts/bin/client-proxy` | Build from `packages/client-proxy` with the same cross-compile flags. |
| `orchestrator` | `artifacts/bin/orchestrator` | Build from `packages/orchestrator`. |
| `template-manager` | `artifacts/bin/template-manager` | Build from `packages/template-manager`. |
| `envd` | `artifacts/bin/envd` | Build from `packages/envd`. |

All binaries **must** be Linux AMD64 executables. The provisioning script aborts if any entry is missing.

You do **not** need to copy Firecracker kernels or versions into the repo. During deployment `deploy-poc.sh` downloads:

- `firecracker` ${FIRECRACKER_RELEASE} → staged to `/usr/local/bin/firecracker` and mirrored under `/fc-versions/${FIRECRACKER_VERSION_FULL}/firecracker`.
- `vmlinux-${FIRECRACKER_KERNEL_VERSION}` → staged to `/var/e2b/kernels/vmlinux-${FIRECRACKER_KERNEL_VERSION}/vmlinux.bin` and mirrored under `/fc-kernels/${FIRECRACKER_KERNEL_VERSION}/vmlinux.bin`.

After the script runs you can verify the assets on the client pool (defaults shown for `FIRECRACKER_VERSION_FULL=v1.10.1_1fcdaec` and `FIRECRACKER_KERNEL_VERSION=6.1.102`):

```bash
ssh -J ubuntu@<bastion-ip> ubuntu@<client-pool-ip> 'ls -l /fc-versions/v1.10.1_1fcdaec/firecracker'
ssh -J ubuntu@<bastion-ip> ubuntu@<client-pool-ip> 'ls -l /fc-kernels/6.1.102/vmlinux.bin'
```

Modify the version constants at the top of `deploy-poc.sh` if you need to pin different Firecracker or kernel releases.

## 1. Package Terraform Bundles

From the repo root (`e2b-on-oci/`):

```bash
zip -r e2b-oci-stack.zip terraform-base
zip -r e2b-oci-cluster.zip terraform-cluster
```

These are the archives you will upload into OCI Resource Manager.

## 2. Apply Terraform (Base & Cluster)

1. In OCI Resource Manager, create a Stack from `e2b-oci-stack.zip` and run `Apply` using the desired compartment, region, CIDRs, SSH key, etc.
2. After the base stack completes, repeat the process with `e2b-oci-cluster.zip`. Capture the following before starting the cluster stack:
   - `private_subnet_id`, `vcn_id`, and `vcn_cidr_block` (from the base stack outputs)
   - `custom_image_ocid`: open OCI Console → **Compute → Custom Images** under the same compartment and copy the latest `e2b-*` image OCID (each build is timestamped). You can also SSH to the bastion and run `cat /opt/e2b/custom_image_ocid.txt`.
   - SSH public key you want injected into the cluster instances
   - Any tag/compartment overrides you plan to reuse
3. Collect the IPs you need for SSH (bastion public IP, server/API/client pool private IPs, etc.) from the OCI Console → Compute → Instances in the target compartment, then copy them into `deploy.env`.

## 3. Stage Artifacts & Runtime Assets

All steps below run from your workstation inside `e2b-on-oci/`.

**Prepare `deploy.env` first**

1. Copy the template and edit it locally (the file is ignored by git):
   ```bash
   cp deploy.env.example deploy.env
   ```
2. Fill in the values:
   - `SSH_USER` remains `ubuntu` for the OCI images we ship (override only if you customized the image).
   - `BASTION_HOST`, `SERVER_POOL_*`, `API_POOL_*`, `CLIENT_POOL_*`: open the OCI Console → **Compute → Instances**, select the compartment you targeted with Terraform, and copy each instance’s public/private IP from the table.
   - `POSTGRES_HOST`: OCI Console → **Oracle Database → PostgreSQL**, select the DB system created by `terraform-base`, and copy its hostname (format `primary.<hash>.postgresql.<region>.oci.oraclecloud.com`).
   - `ARTIFACTS_DIR` can stay at `artifacts/bin` unless you moved the prebuilt binaries elsewhere.
   - Redis settings are optional—the client-proxy uses an in-memory catalog in this POC, so you can leave `REDIS_ENDPOINT` unset unless you explicitly point at the managed Redis cluster.
3. `deploy-poc.sh` and `deploy-services.sh` automatically source `deploy.env`, so once the file is filled out you can run the scripts without additional prompts.

1. Ensure you can reach the bastion via SSH:
   ```bash
   ssh -i ~/.ssh/<key> ubuntu@<bastion-public-ip>
   ```
   From there you can jump to the private nodes using the IPs provided by Terraform.

2. Execute the provisioning script which **syncs this repo to the API/client pools**, uploads binaries, fetches Firecracker assets, and configures directories on both hosts:
   ```bash
   ./deploy-poc.sh
   ```
   - `deploy-poc.sh` now rsyncs the workstation repository (excluding `.git`, zip archives, and `artifacts/bin/`) into `~/e2b` on both the API and client pools before migrations run. All database migrations therefore execute from the freshly synced `packages/db/` directory—no manual `scp` is required.
   - The script prompts for the bastion IP and uses the binaries you staged under `artifacts/bin/`. It also downloads the Firecracker release specified in `deploy-poc.sh` so no manual kernel copy is required.

### Quick cluster sanity check (re-run after services)

After `deploy-poc.sh` completes (and before pushing Nomad jobs), run the validation helper. It reuses `deploy.env` to SSH via the bastion, checks Nomad/Consul membership, verifies Docker/Firecracker assets on the client pool, curls the API & client-proxy `/health` endpoints, and confirms the API node can reach PostgreSQL.

```bash
./scripts/check-cluster.sh
```

> The script emits warnings if SSH host keys changed—clear stale entries with `ssh-keygen -R <private-ip>` as needed. It also requires `jq` on your workstation for the Consul catalog summary.
>
> When you run it **before** `deploy-services.sh`, the API/client-proxy processes are not yet running, so the curls will print the friendly fallback messages (`API not started yet`, `Client proxy not started yet`) instead of failing the script.

> The script is idempotent—run it immediately after `deploy-services.sh` as well to make sure the Nomad jobs stayed healthy. Because it already curls `http://127.0.0.1:50001/health` and `http://127.0.0.1:3001/health` on the API host, you get API/client-proxy validation for free. The client-proxy `/health` endpoint will report `unhealthy` (and you will see `dial tcp 127.0.0.1:4317: connect: connection refused` in the logs) as long as OTEL/Loki are disabled; this is expected until we deploy those collectors or clear the env vars that point to them.

By default the script writes `client-proxy.env` with `REDIS_URL=` (empty) and `USE_CATALOG_RESOLUTION=true`, which lets the sandbox catalog run entirely in-memory on a single client-proxy node. If you later wire up a TLS-enabled Redis cache, populate `REDIS_URL` before re-running the script so that catalog entries persist across restarts.

## 4. Register Nomad Jobs

After `deploy-poc.sh` finishes, push the service jobs into the Nomad cluster:

```bash
./deploy-services.sh
./scripts/check-cluster.sh   # verify Nomad, Consul, and health endpoints
```

This script copies the job specifications to the server pool, runs `nomad job run` for orchestrator, api, client-proxy, and template-manager, and then runs a basic `nomad status` check.

## 5. Initialize the Database (rerun only if needed)

`deploy-poc.sh` already runs the database migrations/seed step during **Phase 1c**, so on a fresh deployment you can move on to the next section. Keep this helper handy in case you tear down the DB, change credentials, or need to reapply the schema manually:

```bash
./scripts/run-init-db.sh
```

This uses the values from `deploy.env`, runs `/opt/e2b/db/init-db.sh` on the API pool (which can reach the private PostgreSQL endpoint), and applies the schema plus seed data. Update `deploy.env` if your database endpoint or credentials differ from the defaults in `terraform-base`.

### API credentials

The seed creates both the **team API key** (`e2b_…`) and the **admin API token** (`sk_e2b_…`). Fetch them directly from PostgreSQL (run the commands below from your workstation; they jump through the bastion to the API node and use the values already present in `deploy.env`):

Run the helper script to pull them out of PostgreSQL (it reuses `deploy.env` for all connection settings and stores the result in `api-creds.env`, which is git-ignored):

```bash
./scripts/export-api-creds.sh
set -a; source api-creds.env; set +a
```

All authenticated requests therefore include **both** headers:

- `X-API-Key: ${TEAM_API_KEY}` (team-scoped key)
- `Authorization: Bearer ${ADMIN_API_TOKEN}` (admin token)

This mirrors the production posture and keeps the client-proxy catalog APIs unlocked.

## 6. Run & Validate the API

> **Automation first:** Once `deploy.env`, `api-creds.env`, and at least one template exist, you can run the helper below to perform the entire validation flow (health checks → sandbox CRUD → hello-world exec → cleanup) automatically via the bastion. Set `VALIDATION_TEMPLATE_ID=<template-id>` (and optionally `VALIDATION_TEMPLATE_ALIAS`) in `deploy.env` if you want to pin a specific template.
>
> ```bash
> ./scripts/validate-api.sh
> ```
>
> The script consumes a pre-built template—the same artifacts the template-manager leaves under `/var/e2b/templates/<template-id>/...` on the client pool. If you need to rebuild a template, follow the manual instructions below (curl commands + `seed-template-image.sh`), then rerun the helper to exercise sandbox CRUD/exec.

With Nomad jobs running and the database initialized, the API is immediately reachable from the private subnet and via the bastion.

1. **Check health endpoints** from your workstation using the bastion as a jump host:

   ```bash
   ssh -J ubuntu@<bastion-ip> ubuntu@<api-pool-ip> 'curl -sf http://127.0.0.1:50001/health'
   ssh -J ubuntu@<bastion-ip> ubuntu@<api-pool-ip> 'curl -sf http://127.0.0.1:3001/health'
   ```

2. **List templates via the API**:

   ```bash
   ssh -J ubuntu@<bastion-ip> ubuntu@<api-pool-ip> \
     "curl -sf -H 'X-API-Key: ${E2B_API_KEY}' http://127.0.0.1:50001/templates | jq"
   ```

3. **Trigger a template build** from your workstation (tunnelled through the bastion):

   ```bash
   ssh -J ubuntu@<bastion-ip> ubuntu@<api-pool-ip> \
     "curl -sf -X POST -H 'X-API-Key: ${E2B_API_KEY}' \
       -H 'Content-Type: application/json' \
       -d '{\"alias\":\"base-oci\",\"dockerfile\":\"FROM ubuntu:22.04\\nRUN echo hello > /hello.txt\",\"cpuCount\":2,\"memoryMB\":512}' \
       http://127.0.0.1:50001/templates"
   ```

   Template-manager logs on the client pool (`nomad alloc logs -stderr <alloc> template-manager`) should show the build progressing to completion.

4. **Expose the API publicly (optional)** by creating an SSH tunnel:

   ```bash
   ssh -i ~/.ssh/<key> -L 50001:<api-pool-ip>:50001 ubuntu@<bastion-ip>
   ```

   With the tunnel open, execute `curl -H "X-API-Key: ${E2B_API_KEY}" http://127.0.0.1:50001/health` from your workstation.

## 7. Exercise Sandbox CRUD & Execution

With the template cached and the catalog populated, run a full sandbox round-trip from the API node (all calls go through the bastion jump host):

1. **Create a sandbox** from the cached template:
   ```bash
   ssh -J ubuntu@<bastion-ip> ubuntu@<api-pool-ip> \
     "curl -sf -X POST \
       -H 'X-API-Key: e2b_...' \
       -H 'Authorization: Bearer ${E2B_API_KEY}' \
       -H 'Content-Type: application/json' \
       -d '{\"templateID\":\"9civuib8exntxta6bgdr\",\"timeout\":600}' \
       http://127.0.0.1:50001/sandboxes"
   ```
   Note the returned `sandboxID`.

2. **Inspect the sandbox** to confirm it is `running`:
   ```bash
   ssh -J ubuntu@<bastion-ip> ubuntu@<api-pool-ip> \
     "curl -sf -H 'X-API-Key: e2b_...' -H 'Authorization: Bearer ${E2B_API_KEY}' \
       http://127.0.0.1:50001/sandboxes/<sandbox-id> | jq"
   ```

3. **Run a "hello world" command** through the client-proxy → orchestrator → envd path:
   ```bash
   ssh -J ubuntu@<bastion-ip> ubuntu@<api-pool-ip> \
     "curl -sf -X POST \
       -H 'X-API-Key: e2b_...' \
       -H 'Authorization: Bearer ${E2B_API_KEY}' \
       -H 'Content-Type: application/json' \
       -d '{\"command\":\"/bin/bash\",\"args\":[\"-lc\",\"echo hello-from-exec && uname -s\"]}' \
       http://127.0.0.1:50001/sandboxes/<sandbox-id>/exec"
   ```
   Expected response:
   ```json
   {"exitCode":0,"stdout":"hello-from-exec\nLinux\n","stderr":"","status":"exit status 0"}
   ```

4. **Delete the sandbox** when finished:
   ```bash
   ssh -J ubuntu@<bastion-ip> ubuntu@<api-pool-ip> \
     "curl -sf -X DELETE \
       -H 'X-API-Key: e2b_...' \
       -H 'Authorization: Bearer ${E2B_API_KEY}' \
       http://127.0.0.1:50001/sandboxes/<sandbox-id>"
   ```

These steps prove CRUD + execution parity with the AWS flow.

> **Snapshot storage:** Every template build leaves its artifacts (rootfs, snapshots, Firecracker metadata) on the client pool under `/var/e2b/templates/<template-id>/...`. Subsequent sandbox creates pull directly from those local assets, so there is no need to rebuild unless you change the template.

## 8. Validation Checklist

1. Verify Nomad cluster health (from the bastion, via SSH jump to a server node):
   ```bash
   ssh -J ubuntu@<bastion-ip> ubuntu@<server-ip> 'nomad status'
   ```
2. Confirm the orchestrator and template-manager allocations are `running` and the API/client-proxy jobs are healthy:
   ```bash
   ssh -J ubuntu@<bastion-ip> ubuntu@<server-ip> 'nomad status orchestrator'
   ssh -J ubuntu@<bastion-ip> ubuntu@<server-ip> 'nomad status template-manager'
   ```
3. Check service health endpoints from the API node:
   ```bash
   ssh -J ubuntu@<bastion-ip> ubuntu@<api-pool-ip> 'curl -sS http://127.0.0.1:50001/health'
   ssh -J ubuntu@<bastion-ip> ubuntu@<api-pool-ip> 'curl -sS http://127.0.0.1:3001/health'
   ```
4. Ensure the local template storage mount exists on the client pool:
   ```bash
   ssh -J ubuntu@<bastion-ip> ubuntu@<client-pool-ip> 'ls -ld /var/e2b/templates'
   ```
5. Confirm the latest template build snapshot artifacts:
   ```bash
   ssh -J ubuntu@<bastion-ip> ubuntu@<client-pool-ip> 'ls -lh /var/e2b/templates/<build-id>'
   ```

If all checks succeed, the environment is ready for API- and template-pipeline validation.

## 9. Capture a Firecracker Snapshot (Optional)

Once the services are up you can generate a reusable Firecracker snapshot for faster cold-starts. The high-level flow is:

1. **Confirm kernel/rootfs assets** on the orchestrator (client) pool. Template builds already stage the kernel under `/fc-kernels/<version>/vmlinux.bin`, but if you need a reference kernel/rootfs for validation you can pull the Firecracker quickstart artifacts:

   ```bash
   curl -o /tmp/vmlinux-quickstart.bin https://s3.amazonaws.com/spec.ccfc.min/img/quickstart_guide/x86_64/kernels/vmlinux.bin
   curl -o /tmp/bionic.rootfs.ext4 https://s3.amazonaws.com/spec.ccfc.min/img/quickstart_guide/x86_64/rootfs/bionic.rootfs.ext4

   sudo mkdir -p /fc-kernels/quickstart
   sudo cp /tmp/vmlinux-quickstart.bin /fc-kernels/quickstart/vmlinux.bin
   sudo chmod 0644 /fc-kernels/quickstart/vmlinux.bin
   ```

   > These sample assets are useful for smoke-tests only; production templates should continue to rely on the template-manager build pipeline so the rootfs matches the Docker image you supply.

2. **Build or reuse a template** (for example via `./create-template.sh`). Note the template alias or ID and make sure at least one successful build exists (`curl -H "X-API-Key: …" $E2B_API_ENDPOINT/templates | jq`).

3. **Run the snapshot helper from this repo**:

   ```bash
   export E2B_API_ENDPOINT="http://<api-pool-ip>"
   export E2B_API_KEY="$(cat ~/.config/e2b/api.key)"

   ./scripts/generate-snapshot.sh \
     --template base-poc \
     --orchestrator-host <client-pool-ip> \
     --ssh-user ubuntu \
     --ssh-key ~/.ssh/id_rsa \
     --bastion-host <bastion-ip>
   ```

   - The script will create a sandbox (unless you pass `--sandbox-id`), send `POST /sandboxes/<id>/pause`, wait for the pause to finish, and optionally confirm the snapshot files over SSH.
   - Pass `--storage-path` if you configured `LOCAL_TEMPLATE_STORAGE_BASE_PATH` to something other than `/var/e2b/templates`.
   - Use `--keep-sandbox` if you plan to resume the same sandbox later.

4. **Verify the snapshot artifacts**. For local storage the files land under `/var/e2b/templates/<build-id>/` on the orchestrator host and include:
   - `snapfile`
   - `memfile` + `memfile.header`
   - `rootfs.ext4` + `rootfs.ext4.header`

   Example validation:

   ```bash
   ssh -J ubuntu@<bastion-ip> ubuntu@<client-pool-ip> 'ls -lh /var/e2b/templates/<build-id>'
   ```

At this point the snapshot can be served back through the standard resume path (`ResumeSandbox`) to match the AWS deployment flow.

## 10. Notes & Troubleshooting

- Both Nomad and Consul run as `root` on the instances. The bootstrap scripts installed via Terraform (`run-nomad.sh`, `run-nomad-client.sh`) handle this automatically.
- Consul/Nomad ACLs remain disabled in this POC build; the scripts and job specs assume open access.
- The template-manager and orchestrator jobs are configured for local template storage (`/var/e2b/templates`) and use the Local artifacts registry driver.
- Observability (OTEL collector, Loki) is not deployed in this milestone; log warnings about `127.0.0.1:4317` can be ignored.
