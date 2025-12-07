# E2B on OCI – Deployment Runbook

This runbook documents the standard procedure for deploying the E2B API and supporting services on Oracle Cloud Infrastructure (OCI). Follow the steps below in sequence to provision infrastructure, stage runtime assets, and validate the platform.

## Repository Overview

```
e2b-on-oci/
├── terraform-policies/    # IAM dynamic group + policies for instance principals/Packer (Stack 1)
├── terraform-base/        # Networking, bastion, object storage buckets, managed PostgreSQL/Redis (Stack 2)
├── terraform-cluster/     # Nomad/Consul/API/client pools (Stack 3)
├── packages/              # Source code for API, orchestrator, client-proxy, template-manager, envd, shared libs
├── nomad/                 # Nomad job definitions (api.hcl, orchestrator.hcl, client-proxy.hcl, template-manager.hcl)
├── deploy-poc.sh          # Provisioning script that pushes binaries/configs and installs dependencies
├── deploy-services.sh     # Registers Nomad jobs after deploy-poc.sh finishes
├── db/                    # init-db.sh + SQL seeds/migrations for the managed PostgreSQL instance
├── deploy.env.example     # Template for the local deployment config (copy to deploy.env, ignored by git)
└── README.md              # This runbook
```

- **terraform-policies**, **terraform-base**, and **terraform-cluster** remain separate stacks so you can iterate on cluster resources without recreating networking/DB resources. Package three stacks and apply them in order: (1) IAM-only `e2b-oci-policies.zip`, (2) `e2b-oci-stack.zip` (base), (3) `e2b-oci-cluster.zip` (cluster).
- **packages/** source code is staged to instances and built directly on the target hosts (no cross-compilation needed).
- **deploy-poc.sh** reads `deploy.env`, connects through the bastion, installs dependencies, uploads env files/binaries, and downloads Firecracker assets. Services are wired for OCI Object Storage + OCIR (no Local storage/registry).
- **terraform-cluster** user-data now enables the `e2b-cleanup-network.timer` on the client pool, which runs every minute to delete idle `ns-*` namespaces and detach orphaned `nbd` devices so template builds never exhaust the slot pool.
- **deploy-services.sh** copies the Nomad job files and runs `nomad job run` for orchestrator, API, client-proxy, and template-manager.
- **db/init-db.sh** seeds the managed PostgreSQL instance (schema + API keys). Automatically called by `deploy-poc.sh` Phase 1d.
- **deploy.env.example** documents every value the scripts need (bastion IP, pool IPs, PostgreSQL host). Copy it to `deploy.env` (ignored by git) and fill it in using the OCI Console outputs.

## Quickstart Overview

1. **Package Terraform** – upload the policies, base, and cluster stacks to OCI Resource Manager.
2. **Apply Terraform** – apply IAM policies first, then base, then cluster; this guarantees the bastion has permissions to launch the Packer builder and create custom images.
3. **Build Binaries & Stage Runtime Assets** – build binaries on instances and stage kernels and configuration.
4. **Register Nomad Jobs** – launch the orchestrator, API, client-proxy, and template-manager.
5. **Initialize PostgreSQL** – load schema and seeds required for the API to authorize requests.
6. **Smoke Test the API** – confirm health endpoints and a template flow from your workstation.
7. **Optional: Seed OCIR** – if you need to push a seed image manually; requires OCIR username/password only for that seeding step (runtime uses Instance Principal).

The sections below expand each step in detail.

## Prerequisites

- macOS or Linux workstation with `zip`, `ssh`, and `scp`.
- Access to the OCI tenancy (Resource Manager + Compute).
- OCI command-line configured locally **or** access to the bastion host created by `terraform-base`.
- Go 1.21+ installed on API and Client pool instances (installed automatically by `deploy-poc.sh`).
- Ability to reach the upstream Firecracker release buckets (used by the provisioning script to fetch kernels and the `firecracker` binary).
- OCIR pulls/pushes require a registry username + auth token. Set `OCIR_USERNAME` = `<namespace>/<username>` and `OCIR_PASSWORD` = an OCI Auth Token (User menu → Auth Tokens). These are used by template-manager/orchestrator to pull from/push to OCIR.
- If the requested OCIR tag is missing, template-manager will bootstrap from a fallback base image (default `python:3.10-slim`, override with `OCIR_FALLBACK_BASE_IMAGE`) and push it under the target tag.

### Build Process

Binaries are built directly on the target instances during `deploy-poc.sh` Phase 2:
- **API and Client Proxy** are built on the API pool
- **Orchestrator, Template Manager, and envd** are built on the Client pool

**Important:** The build process uses your **local repository** (not GitHub). `deploy-poc.sh` Phase 1 stages your local repo to the instances, then Phase 2 builds from that staged code. This means:
- Any local code changes (uncommitted or committed) are included in the build
- No cross-compilation needed (builds natively on Linux)
- Binaries match the target environment exactly
- Go 1.21+ is automatically installed on both pools if not already present

If you make code changes, simply run `deploy-poc.sh` again - it will stage the updated code and rebuild binaries automatically.

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

From the repo root (`e2b-on-oci/`), run the helper script (defaults to `us-ashburn-1`):

```bash
./package_terraform_bundles.sh [region]
```

Examples:
- `./package_terraform_bundles.sh` → uses `us-ashburn-1`
- `./package_terraform_bundles.sh ap-sydney-1`

The script substitutes any `__REGION__` placeholders in Nomad jobs and bootstrap scripts before zipping. Region must be set in three places and should match:
- Terraform stack input (`var.region` when applying stacks)
- Packaging time for Nomad/user-data (`./package_terraform_bundles.sh [region]`)
- Runtime env (`OCI_REGION` in `deploy.env` used by services)

It emits three bundles in the repo root:
- `e2b-oci-policies.zip`
- `e2b-oci-stack.zip`
- `e2b-oci-cluster.zip`

Apply them in the order listed above so the IAM/DG changes are active before the bastion user data runs Packer.

## 2. Apply Terraform (Policies → Base → Cluster)

1. In OCI Resource Manager, create a Stack from `e2b-oci-policies.zip` and run `Apply` in your home region. This bootstraps the dynamic group + policies needed for instance principal/Packer.
2. After the policies stack finishes propagating, create and apply `e2b-oci-stack.zip` (base) using the desired compartment, region, CIDRs, SSH key, etc.
3. After the base stack completes, apply `e2b-oci-cluster.zip`. Capture the following before starting the cluster stack:
   - `private_subnet_id`, `vcn_id`, and `vcn_cidr_block` (from the base stack outputs)
   - `custom_image_ocid`: open OCI Console → **Compute → Custom Images** under the same compartment and copy the latest `e2b-*` image OCID (each build is timestamped). You can also SSH to the bastion and run `cat /opt/e2b/custom_image_ocid.txt`.
   - SSH public key you want injected into the cluster instances
   - Any tag/compartment overrides you plan to reuse
4. Collect the IPs you need for SSH (bastion public IP, server/API/client pool private IPs, etc.) from the OCI Console → Compute → Instances in the target compartment, then copy them into `deploy.env`.

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
   - Redis settings are optional—the client-proxy uses an in-memory catalog in this POC, so you can leave `REDIS_ENDPOINT` unset unless you explicitly point at the managed Redis cluster.
   - **Object Storage & OCIR (required at runtime):** `OCI_REGION`, `OCI_NAMESPACE`, `TEMPLATE_BUCKET_NAME`, `OCI_CONTAINER_REPOSITORY_NAME` (use outputs from `terraform-base` for namespace/repo, and the chosen template bucket). Set `OCIR_USERNAME`/`OCIR_PASSWORD` (auth token) so services can pull from OCIR.
3. `deploy-poc.sh` and `deploy-services.sh` automatically source `deploy.env`, so once the file is filled out you can run the scripts without additional prompts.

1. Ensure you can reach the bastion via SSH:
   ```bash
   ssh -i ~/.ssh/<key> ubuntu@<bastion-public-ip>
   ```
   From there you can jump to the private nodes using the IPs provided by Terraform.

2. Execute the provisioning script which **syncs this repo to the API/client pools**, builds binaries, fetches Firecracker assets, configures directories, and initializes the database:
   ```bash
   ./deploy-poc.sh
   ```
   - `deploy-poc.sh` stages the workstation repository (excluding `.git` and zip archives) into `~/e2b` on both the API and client pools before migrations run. All database migrations therefore execute from the freshly synced `packages/db/` directory—no manual `scp` is required.
   - Binaries are built directly on the instances during Phase 2 (see Build Process section above). The script also downloads the Firecracker release specified in `deploy-poc.sh` so no manual kernel copy is required.
   - **Phase 1d automatically initializes the database** (runs migrations, seeds users/teams, and configures cluster settings). The script will **fail with an error** if database initialization fails, ensuring issues are caught immediately.

### Pre-Deployment Validation

After `deploy-poc.sh` completes (and before pushing Nomad jobs), run the pre-deployment validation script. It verifies binaries, configuration, node classes, infrastructure health, database initialization, and service readiness.

```bash
./scripts/check-pre-deploy.sh
```

The script performs comprehensive pre-deployment checks:
- **Binaries**: Verifies required binaries exist on API and client pools (including `envd`)
- **Configuration**: Checks environment files and Nomad client configuration (`no_cgroups`, `node_class` in config files)
- **Infrastructure**: Nomad server health, Consul cluster membership
- **Database**: Validates database connectivity, initialization status, team/cluster configuration
- **Client Pool Readiness**: Docker service, template directories, Firecracker kernels
- **Nomad Client Service**: Verifies Nomad client service is active
- **Summary**: Provides a clear pass/fail summary with counts and specific failed/warned items

> The script emits warnings if SSH host keys changed—clear stale entries with `ssh-keygen -R <private-ip>` as needed. It also requires `jq` on your workstation for parsing JSON responses.
>
> This script only checks infrastructure and configuration that exists **before** services are deployed. For service health, template builders, Consul agent health, and Nomad job status, run `check-post-deploy.sh` after `deploy-services.sh`.


## 4. Register Nomad Jobs

After `deploy-poc.sh` finishes, push the service jobs into the Nomad cluster:

```bash
./deploy-services.sh
./scripts/check-post-deploy.sh    # comprehensive post-deployment verification
```

`deploy-services.sh` copies the job specifications to the server pool, runs `nomad job run` for orchestrator, api, client-proxy, and template-manager, and then prints a **summary for all four critical jobs**. It exits with code 1 if any of them has no running allocations so you can fail fast.

**API credentials are automatically refreshed by `validate-api.sh`** when you run validation. If you need credentials before running validation, run `./scripts/export-api-creds.sh` manually.

`scripts/check-post-deploy.sh` performs comprehensive post-deployment verification:
- **Critical Nomad Jobs**: Verifies `orchestrator`, `template-manager`, `api`, and `client-proxy` all have running allocations
- **Service Health**: Checks API and Client Proxy health endpoints
- **Node Class Validation**: Ensures node classes are correctly set (required for job placement)
- **Infrastructure**: Nomad server health, Consul service discovery and agent health, PostgreSQL connectivity
- **Consul Health**: Verifies Consul agents are healthy on both API and client pools
- **Node Status**: Shows all Nomad nodes with their classes and status
- **Template Builders**: Checks for available template builders (requires `api-creds.env`, automatically refreshed by `validate-api.sh`)
- **Summary**: Provides a clear pass/fail summary with counts and specific failed/warned items

The script exits with code 1 if any critical job is unhealthy, making it suitable for CI/CD pipelines.

## 5. Run & Validate the API

> **Automation first:** After `deploy-services.sh` completes, `api-creds.env` is automatically available (exported during deployment). You can immediately run the validation script to perform the entire validation flow (health checks → sandbox CRUD → hello-world exec → cleanup) automatically via the bastion:
>
> ```bash
> ./scripts/validate-api.sh
> ```
>
> The script consumes a pre-built template—the same artifacts the template-manager leaves under `/var/e2b/templates/<template-id>/...` on the client pool. Set `VALIDATION_TEMPLATE_ID=<template-id>` (and optionally `VALIDATION_TEMPLATE_ALIAS`) in `deploy.env` if you want to pin a specific template. The script automatically builds a fresh template if none is specified.
>
> **Note:** All authenticated API requests require both headers:
> - `X-API-Key: ${TEAM_API_KEY}` (team-scoped key, format: `e2b_…`)
> - `Authorization: Bearer ${ADMIN_API_TOKEN}` (admin token, format: `sk_e2b_…`)
>
> If you need to manually export credentials (e.g., after re-initializing the database), run: `./scripts/export-api-creds.sh`

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

   This creates a template and returns a `templateID` and `buildID`. Before triggering the build, you need to seed the Docker image on the client pool using `seed-template-image.sh`:

   ```bash
   ./seed-template-image.sh \
     --template-id <template-id> \
     --build-id <build-id> \
     --client-host <client-pool-ip> \
     --bastion-host <bastion-ip> \
     --dockerfile "FROM ubuntu:22.04\nRUN echo hello > /hello.txt"
   ```

   Then trigger the build:

   ```bash
   ssh -J ubuntu@<bastion-ip> ubuntu@<api-pool-ip> \
     "curl -sf -X POST -H 'X-API-Key: ${E2B_API_KEY}' \
       http://127.0.0.1:50001/templates/<template-id>/builds/<build-id>"
   ```

   Template-manager logs on the client pool (`nomad alloc logs -stderr <alloc> template-manager`) should show the build progressing to completion.

   **Optional: push seed image to OCIR.** If you want `seed-template-image.sh` to push to OCIR (instead of local-only), set:
   - `OCIR_TEMPLATE_REPOSITORY_PATH="<region>.ocir.io/<namespace>/<repo>"` (aligns with `OCI_REGION`/`OCI_NAMESPACE`/`OCI_CONTAINER_REPOSITORY_NAME`)
   - `OCIR_USERNAME`, `OCIR_PASSWORD` (OCI registry username + Auth Token; create under User Settings → Auth Tokens). The script does not mint a token via Instance Principal.

   **Note:** The `validate-api.sh` script automatically handles template building and seeding, so manual use of `seed-template-image.sh` is only needed for custom template builds outside of validation.

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

> **Snapshot/storage:** Template artifacts are stored in OCI Object Storage (`TEMPLATE_BUCKET_NAME`) and images in OCIR; local copies may exist on the client for runtime. Ensure envs are set for `STORAGE_PROVIDER=OCIBucket`, `ARTIFACTS_REGISTRY_PROVIDER=OCI_OCIR`, and `OCIR_USERNAME`/`OCIR_PASSWORD` (auth token).

## 8. Validation

All validation is automated via the check scripts:

- **Pre-deployment**: Run `./scripts/check-pre-deploy.sh` after `deploy-poc.sh` to verify infrastructure, binaries, configuration, and database initialization.
- **Post-deployment**: Run `./scripts/check-post-deploy.sh` after `deploy-services.sh` to verify Nomad jobs, service health, Consul agents, and template builders.
- **API validation**: Run `./scripts/validate-api.sh` to perform end-to-end API validation (template builds, sandbox CRUD, execution).

These scripts provide comprehensive validation with clear pass/fail summaries. Manual validation steps are no longer needed.

## 9. Optional: Manual Verification

If you need to manually verify specific aspects, you can use the same commands that the check scripts use:

- **Nomad job status**: `ssh -J ubuntu@<bastion-ip> ubuntu@<server-ip> 'nomad status <job-name>'`
- **Service health**: `ssh -J ubuntu@<bastion-ip> ubuntu@<api-pool-ip> 'curl -sS http://127.0.0.1:50001/health'`
- **Template storage**: `ssh -J ubuntu@<bastion-ip> ubuntu@<client-pool-ip> 'ls -ld /var/e2b/templates'`

However, the automated check scripts (`check-pre-deploy.sh` and `check-post-deploy.sh`) cover all these checks comprehensively.

## 10. Capture a Firecracker Snapshot (Optional)

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
- The template-manager and orchestrator jobs are configured for OCI storage/registry (`STORAGE_PROVIDER=OCIBucket`, `ARTIFACTS_REGISTRY_PROVIDER=OCI_OCIR`).
- Observability (OTEL collector, Loki) is not deployed in this milestone; log warnings about `127.0.0.1:4317` can be ignored.
