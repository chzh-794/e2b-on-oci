# Validation Checklist for E2B on OCI

## What to Validate Before Pushing

### 1. Terraform Changes (terraform-base/ or terraform-cluster/)

**Required before commit:**
- [ ] Regenerate zip files:
  cd terraform-base && zip -r ../e2b-oci-stack.zip . -x "*.terraform*" -x "*.tfstate*" -x "*.tfvars"
  cd terraform-cluster && zip -r ../e2b-oci-cluster.zip . -x "*.terraform*" -x "*.tfstate*" -x "*.tfvars"
  - [ ] Commit both Terraform changes AND updated zip files together
- [ ] Upload zip to OCI Resource Manager
- [ ] Run **Plan** in Resource Manager (must succeed)
- [ ] Run **Apply** in Resource Manager
- [ ] Run `./deploy-poc.sh`
- [ ] Run `./scripts/check-pre-deploy.sh` (must pass)
- [ ] Run `./deploy-services.sh`
- [ ] Run `./scripts/validate-api.sh` (must pass)

### 2. Code Changes (packages/*)

**Applies to:** packages/api, packages/orchestrator, packages/client-proxy, packages/envd, packages/shared, packages/db

**Required before commit:**
- [ ] Run `./deploy-poc.sh` (stages code to instances and builds binaries)
- [ ] Run `./scripts/check-pre-deploy.sh` (verifies binaries built correctly)
- [ ] Run `./deploy-services.sh` (deploys services with new binaries)
- [ ] Run `./scripts/validate-api.sh` (must pass)

### 3. Deployment Script Changes (deploy-poc.sh, deploy-services.sh, scripts/*)

**Required before commit:**
- [ ] Run `./deploy-poc.sh` (if deploy-poc.sh changed)
- [ ] Run `./scripts/check-pre-deploy.sh` (must pass)
- [ ] Run `./deploy-services.sh` (if deploy-services.sh changed)
- [ ] Run `./scripts/validate-api.sh` (must pass)

### 4. Nomad Job Definition Changes (nomad/*.hcl)

**Applies to:** nomad/api.hcl, nomad/orchestrator.hcl, nomad/client-proxy.hcl, nomad/template-manager.hcl

**Required before commit:**
- [ ] Run `./deploy-services.sh` (redeploys jobs with new configuration)
- [ ] Run `./scripts/check-post-deploy.sh` (verifies jobs running)
- [ ] Run `./scripts/validate-api.sh` (must pass)

**Note:** Skip `deploy-poc.sh` - binaries don't need rebuilding for config-only changes.

### 5. Database Changes (db/*)

**Applies to:** db/migrations/, db/simple-seed.sql, db/init-db.sh

**Required before commit:**
- [ ] Run `./deploy-poc.sh` (runs migrations in Phase 1d)
- [ ] Run `./scripts/check-pre-deploy.sh` (verifies DB initialized)
- [ ] Run `./deploy-services.sh`
- [ ] Run `./scripts/validate-api.sh` (must pass)
