# OCI Storage Migration Guide

## Overview
This document explains where AWS uses S3/ECR and what needs to be changed in OCI to use Object Storage and Container Registry.

## AWS S3 Usage

### 1. Template Storage (S3 Bucket)
**Purpose**: Store template rootfs files (rootfs.ext4, memfile, snapfile) for Firecracker VMs.

**AWS Implementation**:
- **File**: `packages/shared/pkg/storage/storage_aws.go`
- **Provider constant**: `AWSStorageProvider = "AWSBucket"`
- **Environment variables**:
  - `STORAGE_PROVIDER="AWSBucket"`
  - `TEMPLATE_BUCKET_NAME="<s3-bucket-name>"`
- **AWS SDK**: Uses `github.com/aws/aws-sdk-go-v2/service/s3` with IAM instance roles

**Key Operations**:
- `WriteFromFileSystem()` - Upload template files to S3
- `WriteTo()` - Download template files from S3
- `ReadAt()` - Read specific byte ranges (for NBD streaming)
- `DeleteObjectsWithPrefix()` - Clean up old template builds
- `Size()` - Get object size

**Where it's configured**:
- `sample-e2b-on-aws/nomad/origin/template-manager.hcl` (line 37, 46)
- `sample-e2b-on-aws/nomad/origin/orchestrator.hcl` (line 38, 44)

### 2. Artifacts Registry (AWS ECR)
**Purpose**: Store Docker images for template builds (base images, build artifacts).

**AWS Implementation**:
- **File**: `packages/shared/pkg/artifacts-registry/registry_aws.go`
- **Provider constant**: `AWSStorageProvider = "AWS_ECR"`
- **Environment variables**:
  - `ARTIFACTS_REGISTRY_PROVIDER="AWS_ECR"`
  - `AWS_DOCKER_REPOSITORY_NAME="e2bdev/base"`
  - `AWS_REGION="<region>"`
- **AWS SDK**: Uses `github.com/aws/aws-sdk-go-v2/service/ecr` with IAM instance roles

**Key Operations**:
- `GetTag()` - Get ECR image tag for template/build
- `GetImage()` - Pull Docker image from ECR
- `Delete()` - Delete image from ECR

**Where it's configured**:
- `sample-e2b-on-aws/nomad/origin/template-manager.hcl` (line 38, 39, 42)
- `sample-e2b-on-aws/nomad/origin/orchestrator.hcl` (line 45)

## OCI Migration Required Changes

### Files to Create

#### 1. `packages/shared/pkg/storage/storage_oci.go`
**Purpose**: Implement OCI Object Storage provider (equivalent to `storage_aws.go`)

**Required Implementation**:
```go
type OCIBucketStorageProvider struct {
    client     *objectstorage.ObjectStorageClient
    namespace  string
    bucketName string
    region     string
}

type OCIBucketStorageObjectProvider struct {
    client     *objectstorage.ObjectStorageClient
    namespace  string
    bucketName string
    path       string
    ctx        context.Context
}
```

**Key Methods** (mirror AWS implementation):
- `NewOCIBucketStorageProvider()` - Initialize with OCI SDK using instance principal
- `WriteFromFileSystem()` - Upload using `PutObject()`
- `WriteTo()` - Download using `GetObject()`
- `ReadAt()` - Use `GetObject()` with `Range` header
- `DeleteObjectsWithPrefix()` - List + batch delete
- `Size()` - Use `HeadObject()`

**OCI SDK**: `github.com/oracle/oci-go-sdk/v65/objectstorage`

#### 2. `packages/shared/pkg/artifacts-registry/registry_oci.go`
**Purpose**: Implement OCI Container Registry (OCIR) provider (equivalent to `registry_aws.go`)

**Note**: OCI Container Registry is managed via the Artifacts service. The Terraform resource is `oci_artifacts_container_repository`, and the API is under the Artifacts namespace, but the service is commonly referred to as "Container Registry" or "OCIR" in documentation.

**Required Implementation**:
```go
type OCIArtifactsRegistry struct {
    repositoryName string
    namespace      string
    region         string
    endpoint       string  // e.g., "iad.ocir.io"
    client         *artifacts.ArtifactsClient
    authProvider   common.ConfigurationProvider  // For generating auth tokens
}
```

**Key Methods**:
- `NewOCIArtifactsRegistry()` - Initialize with OCI SDK using instance principal
  - Get namespace from Object Storage API
  - Build endpoint: `<region>.ocir.io`
  - Initialize Artifacts client for repository management
- `GetTag()` - Build full image path: `<region>.ocir.io/<namespace>/<repository>:<tag>`
- `GetImage()` - Pull using `go-containerregistry` with OCI auth token
  - Generate auth token using `artifacts.GetAuthorizationToken()` or instance principal
  - Use token for Docker-style authentication
- `Delete()` - Delete image using OCI Artifacts API (`DeleteContainerImage`)

**OCI SDK**: 
- `github.com/oracle/oci-go-sdk/v65/artifacts` (for repository/image management)
- `github.com/oracle/oci-go-sdk/v65/common` (for auth token generation)
- `github.com/google/go-containerregistry` (for Docker image operations)

**Important**: OCIR uses Docker-style authentication. You'll need to:
1. Generate an auth token using instance principal or user credentials
2. Use the token as password for Docker login (username format: `<namespace>/<username>` or `OCI_<user_ocid>`)
3. For `go-containerregistry`, use `authn.Basic` with the token

### Files to Modify

#### 1. `packages/shared/pkg/storage/storage.go`
**Add OCI provider constant and switch case**:
```go
const (
    GCPStorageProvider   Provider = "GCPBucket"
    AWSStorageProvider   Provider = "AWSBucket"
    OCIStorageProvider   Provider = "OCIBucket"  // NEW
    LocalStorageProvider Provider = "Local"
)

func GetTemplateStorageProvider(ctx context.Context) (StorageProvider, error) {
    // ... existing code ...
    switch provider {
    case AWSStorageProvider:
        return NewAWSBucketStorageProvider(ctx, bucketName)
    case GCPStorageProvider:
        return NewGCPBucketStorageProvider(ctx, bucketName)
    case OCIStorageProvider:  // NEW
        return NewOCIBucketStorageProvider(ctx, bucketName)
    }
    // ...
}
```

#### 2. `packages/shared/pkg/artifacts-registry/registry.go`
**Add OCI provider constant and switch case**:
```go
const (
    GCPStorageProvider   RegistryProvider = "GCP_ARTIFACTS"
    AWSStorageProvider   RegistryProvider = "AWS_ECR"
    OCIStorageProvider   RegistryProvider = "OCI_OCIR"  // NEW
    LocalStorageProvider RegistryProvider = "Local"
)

func GetArtifactsRegistryProvider() (ArtifactsRegistry, error) {
    // ... existing code ...
    switch provider {
    case AWSStorageProvider:
        return NewAWSArtifactsRegistry(setupCtx)
    case GCPStorageProvider:
        return NewGCPArtifactsRegistry(setupCtx)
    case OCIStorageProvider:  // NEW
        return NewOCIArtifactsRegistry(setupCtx)
    }
    // ...
}
```

#### 3. `nomad/template-manager.hcl`
**Change environment variables**:
```hcl
env {
    NODE_ID                          = "$${node.unique.id}"
    STORAGE_PROVIDER                 = "OCIBucket"  # Changed from "Local"
    TEMPLATE_BUCKET_NAME             = "${oci_bucket_name}"  # Changed from "local"
    ARTIFACTS_REGISTRY_PROVIDER      = "OCI_OCIR"  # Changed from "Local"
    OCI_REGION                       = "${oci_region}"  # NEW (e.g., "us-ashburn-1")
    OCI_NAMESPACE                    = "${oci_namespace}"  # NEW (Object Storage namespace, same for OCIR)
    OCI_CONTAINER_REPOSITORY_NAME    = "${oci_repo_name}"  # NEW (display_name from Terraform)
    # ... other vars ...
}
```

**Note**: The OCIR endpoint (`<region>.ocir.io/<namespace>/<repo>`) will be constructed in code from these variables.

#### 4. `nomad/orchestrator.hcl`
**Change environment variables**:
```hcl
env {
    NODE_ID                  = "$${node.unique.id}"
    STORAGE_PROVIDER         = "OCIBucket"  # Changed from "Local"
    TEMPLATE_BUCKET_NAME     = "${oci_bucket_name}"  # Changed from "local"
    ARTIFACTS_REGISTRY_PROVIDER = "OCI_OCIR"  # Changed from "Local"
    OCI_REGION               = "${oci_region}"  # NEW
    # ... other vars ...
}
```

#### 5. `deploy-poc.sh`
**Update environment variable assignments**:
```bash
# Template Manager env
STORAGE_PROVIDER=OCIBucket  # Changed from Local
TEMPLATE_BUCKET_NAME=<oci-bucket-name>  # Changed from "local"
ARTIFACTS_REGISTRY_PROVIDER=OCI_OCIR  # Changed from Local
OCI_REGION=<region>  # NEW (e.g., "us-ashburn-1")
OCI_NAMESPACE=<namespace>  # NEW (Object Storage namespace, same for OCIR)
OCI_CONTAINER_REPOSITORY_NAME=<repo-name>  # NEW (display_name from Terraform)

# Orchestrator env (similar changes, but doesn't need ARTIFACTS_REGISTRY_PROVIDER)
STORAGE_PROVIDER=OCIBucket
TEMPLATE_BUCKET_NAME=<oci-bucket-name>
OCI_REGION=<region>
OCI_NAMESPACE=<namespace>
```

### Terraform Changes

**Object Storage Buckets**: Already provisioned in `terraform-base/main.tf`:
- Buckets are created via `module.object_storage_buckets` when `enable_object_storage = true`
- Existing buckets include: `fc-template`, `fc-env-pipeline`, `docker-contexts`, etc.
- See `terraform-base/modules/object_storage_bucket/` for bucket configuration
- **No changes needed** - use existing `fc-template` bucket or add new bucket to `local.object_storage_buckets` map

**Container Registry (OCIR)**: Not currently provisioned. Add to `terraform-base/main.tf` or `terraform-cluster/main.tf`:

```hcl
# Get Object Storage namespace (same namespace used for OCIR)
data "oci_objectstorage_namespace" "ns" {
    compartment_id = var.compartment_ocid
}

# Create Container Registry repository for Docker images
# Note: Container Registry is managed via the Artifacts service in Terraform
# Reference: https://docs.oracle.com/en-us/iaas/Content/Registry/home.htm
# Terraform resource: oci_artifacts_container_repository
resource "oci_artifacts_container_repository" "template_registry" {
    compartment_id = var.compartment_ocid
    display_name   = "e2b-templates"  # Must be unique within tenancy
    is_public      = false
    is_immutable   = false  # Allow overwriting tags
}

# Output the OCIR endpoint format: <region>.ocir.io/<namespace>/<repository>
output "ocir_endpoint" {
    value = "${var.region}.ocir.io/${data.oci_objectstorage_namespace.ns.namespace}/${oci_artifacts_container_repository.template_registry.display_name}"
}
```

**Important Notes**:
- **Object Storage**: Already exists in `terraform-base` - no changes needed
- **Container Registry**: Managed via OCI Artifacts service (not a separate "Container Registry" service)
- Terraform resource: `oci_artifacts_container_repository` (found in `terraform-provider-oci/examples/artifacts/`)
- OCIR endpoint format: `<region>.ocir.io/<namespace>/<repository>:<tag>`
- The `namespace` is the same Object Storage namespace (unique per tenancy)
- Container repository `display_name` must be unique within the tenancy
- OCIR authentication uses auth tokens (not instance principal directly for Docker)
- For Docker operations, you'll need to generate an auth token and use it with `docker login`

### Authentication

**AWS**: Uses IAM roles for EC2 instances (automatic via `config.LoadDefaultConfig()`)
- **AWS IAM** (Identity and Access Management) is AWS's identity service
- EC2 instances can be assigned IAM roles that grant permissions to access AWS services
- When an EC2 instance has an IAM role attached, applications can automatically obtain temporary credentials via the instance metadata service
- No access keys needed - AWS SDK automatically uses the instance's IAM role credentials

**OCI Object Storage**: Uses Instance Principals (automatic via OCI SDK when running on OCI instances):
- **OCI IAM** (Identity and Access Management) is OCI's identity service
- **Instance Principals** is OCI's mechanism for compute instances to authenticate (equivalent to AWS IAM roles for EC2)
- OCI compute instances must be in a Dynamic Group with appropriate IAM policies
- OCI SDK automatically detects and uses instance principal credentials (no access keys needed)
- Similar to AWS: applications get temporary credentials automatically via instance metadata

```go
import "github.com/oracle/oci-go-sdk/v65/common"
import "github.com/oracle/oci-go-sdk/v65/objectstorage"

provider := common.DefaultConfigProvider()  // Auto-detects instance principal
client, err := objectstorage.NewObjectStorageClientWithConfigurationProvider(provider)
```

**OCI Container Registry (OCIR)**: Uses auth tokens for Docker operations:
- For repository management (create/delete/list): Instance Principal works via Artifacts API
- For Docker push/pull: Requires auth token
  - Generate token using instance principal: `artifacts.GetAuthorizationToken()`
  - Or use user auth token if available
  - Docker login format: `docker login <region>.ocir.io -u '<namespace>/<username>' -p '<auth-token>'`
  - For `go-containerregistry`: Use `authn.Basic` with username and token

**Example OCIR auth in Go**:
```go
// Get auth token using instance principal
authProvider := common.DefaultConfigProvider()
artifactsClient, _ := artifacts.NewArtifactsClientWithConfigurationProvider(authProvider)
tokenResp, _ := artifactsClient.GetAuthorizationToken(context.Background(), artifacts.GetAuthorizationTokenRequest{})

// Use token for Docker authentication
auth := &authn.Basic{
    Username: fmt.Sprintf("%s/%s", namespace, "OCI_<instance_ocid>"),
    Password: *tokenResp.Token,
}
```

### Environment Variables Summary

| Purpose | AWS Variable | OCI Variable (New) |
|---------|-------------|-------------------|
| Storage Provider | `STORAGE_PROVIDER="AWSBucket"` | `STORAGE_PROVIDER="OCIBucket"` |
| Template Bucket | `TEMPLATE_BUCKET_NAME="<s3-bucket>"` | `TEMPLATE_BUCKET_NAME="<oci-bucket>"` |
| Artifacts Registry | `ARTIFACTS_REGISTRY_PROVIDER="AWS_ECR"` | `ARTIFACTS_REGISTRY_PROVIDER="OCI_OCIR"` |
| Region | `AWS_REGION="<region>"` | `OCI_REGION="<region>"` (e.g., "us-ashburn-1") |
| Namespace | (not needed) | `OCI_NAMESPACE="<namespace>"` (Object Storage namespace, same for OCIR) |
| Container Registry Repo | `AWS_DOCKER_REPOSITORY_NAME="e2bdev/base"` | `OCI_CONTAINER_REPOSITORY_NAME="<repo-name>"` (display_name from Terraform) |
| OCIR Endpoint | (auto from region) | Auto-built as: `<region>.ocir.io/<namespace>/<repo>` |

**Note**: OCIR endpoint is constructed from region + namespace + repository name. The namespace can be retrieved via `data.oci_objectstorage_namespace` in Terraform or via OCI API at runtime.

### Testing Checklist

1. ✅ Create `storage_oci.go` with all required methods
2. ✅ Create `registry_oci.go` with all required methods
3. ✅ Update `storage.go` to include OCI provider
4. ✅ Update `registry.go` to include OCI provider
5. ✅ Update Nomad job files with OCI env vars
6. ✅ Update `deploy-poc.sh` with OCI env vars
7. ✅ Test template build with OCI Object Storage
8. ✅ Test template build with OCI Container Registry
9. ✅ Verify NBD streaming works with OCI Object Storage
10. ✅ Verify cleanup (DeleteObjectsWithPrefix) works

### References

- **AWS S3 Implementation**: `sample-e2b-on-aws/packages/shared/pkg/storage/storage_aws.go`
- **AWS ECR Implementation**: `sample-e2b-on-aws/packages/shared/pkg/artifacts-registry/registry_aws.go`
- **OCI Go SDK Docs**: https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/gosdk.htm
- **OCI Go SDK Github**: https://github.com/oracle/oci-go-sdk
- **OCI Object Storage API**: https://docs.oracle.com/en-us/iaas/api/#/en/objectstorage/20160918/
- **OCI Container Registry Documentation**: https://docs.oracle.com/en-us/iaas/Content/Registry/home.htm
- **OCI Artifacts API** (Container Registry is managed via Artifacts service): https://docs.oracle.com/en-us/iaas/api/#/en/artifacts/20260918/ContainerRepository/
- **Terraform Provider Example**: Found in `terraform-provider-oci/examples/artifacts/ContainerRepository/container_repository.tf`
- **Existing Object Storage**: Already provisioned in `terraform-base/main.tf` (see `local.object_storage_buckets` and `module.object_storage_buckets`)

