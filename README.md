# E2B on OCI – Deployment Runbook

This document captures the exact workflow we use to stand up the OCI proof-of-concept environment so that a customer can reproduce it end-to-end.

## Prerequisites

- macOS or Linux workstation with `zip`, `ssh`, and `scp`.
- Access to the OCI tenancy (Resource Manager + Compute).
- OCI command-line configured locally **or** access to the bastion host created by `terraform-base`.
- Prebuilt binaries populated in `artifacts/bin/` (already provided in this repository).

## 1. Package Terraform Bundles

From the repo root (`e2b-on-oci/`):

```bash
zip -r e2b-oci-stack.zip terraform-base
zip -r e2b-oci-cluster.zip terraform-cluster
```

These are the archives you will upload into OCI Resource Manager.

## 2. Apply Terraform (Base & Cluster)

1. In OCI Resource Manager, create a Stack from `e2b-oci-stack.zip` and run `Apply` using the desired compartment, region, CIDRs, SSH key, etc.
2. After the base stack completes, repeat the process with `e2b-oci-cluster.zip`.
3. Record the outputs you need for SSH (bastion public IP, server pool private IPs, etc.).

## 3. Stage Artifacts & Runtime Assets

All steps below run from your workstation inside `e2b-on-oci/`.

1. Ensure you can reach the bastion via SSH:
   ```bash
   ssh -i ~/.ssh/<key> ubuntu@<bastion-public-ip>
   ```
   From there you can jump to the private nodes using the IPs provided by Terraform.

2. Execute the provisioning script which uploads binaries, env files, Firecracker kernel assets, and configures directories on the API/client pools:
   ```bash
   ./deploy-poc.sh
   ```
   The script prompts for the bastion IP and relies on `artifacts/bin/*` for the service binaries.

## 4. Register Nomad Jobs

After `deploy-poc.sh` finishes, push the service jobs into the Nomad cluster:

```bash
./deploy-services.sh
```

This script copies the job specifications to the server pool, runs `nomad job run` for orchestrator, api, client-proxy, and template-manager, and then runs a basic `nomad status` check.

## 5. Validation Checklist

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

If all checks succeed, the environment is ready for API- and template-pipeline validation.

## Notes & Troubleshooting

- Both Nomad and Consul run as `root` on the instances. The bootstrap scripts installed via Terraform (`run-nomad.sh`, `run-nomad-client.sh`) handle this automatically.
- Consul/Nomad ACLs remain disabled in this POC build; the scripts and job specs assume open access.
- The template-manager and orchestrator jobs are configured for local template storage (`/var/e2b/templates`) and use the Local artifacts registry driver.
- Observability (OTEL collector, Loki) is not deployed in this milestone; log warnings about `127.0.0.1:4317` can be ignored.
