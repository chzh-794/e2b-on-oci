#!/usr/bin/env bash

set -euo pipefail

region="${1:-us-ashburn-1}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${script_dir}"

staging="$(mktemp -d "${TMPDIR:-/tmp}/e2b-packaging.XXXX")"
cleanup() {
  rm -rf "$staging"
}
trap cleanup EXIT

copy_stack() {
  local name="$1"
  rsync -a --delete \
    --exclude '.terraform' \
    --exclude '.terraform.lock.hcl' \
    --exclude '.DS_Store' \
    "${repo_root}/${name}" "${staging}/"
}

copy_stack "terraform-policies"
copy_stack "terraform-base"
copy_stack "terraform-cluster"

# Replace region placeholder before packaging to make bundles region-aware.
declare -a region_placeholder_files=(
  "nomad/api.hcl"
  "nomad/client-proxy.hcl"
  "nomad/orchestrator.hcl"
  "nomad/template-manager.hcl"
  "terraform-cluster/scripts/run-consul.sh"
  "terraform-cluster/scripts/run-consul-client.sh"
  "terraform-cluster/scripts/run-nomad.sh"
  "terraform-cluster/scripts/run-nomad-client.sh"
)

for rel_path in "${region_placeholder_files[@]}"; do
  src_path="${repo_root}/${rel_path}"
  dest_path="${staging}/${rel_path}"
  if [[ ! -f "$src_path" ]]; then
    echo "Skipping missing file: ${rel_path}" >&2
    continue
  fi
  mkdir -p "$(dirname "$dest_path")"
  cp "$src_path" "$dest_path"
  python - "$dest_path" "$region" <<'PY'
import sys
path, region = sys.argv[1:]
data = open(path, "r", encoding="utf-8").read()
data = data.replace("__REGION__", region)
open(path, "w", encoding="utf-8").write(data)
PY

  # Refresh compressed versions when present to keep Terraform base64 payloads in sync.
  case "$rel_path" in
    terraform-cluster/scripts/run-*.sh)
      gzip -c "$dest_path" > "${dest_path}.gz"
      ;;
  esac
done

# Stage Nomad jobs inside the cluster stack so they are included in the bundle.
mkdir -p "${staging}/terraform-cluster/nomad"
cp -R "${staging}/nomad/." "${staging}/terraform-cluster/nomad/"

cd "$staging"
zip -rq "${repo_root}/e2b-oci-policies.zip" terraform-policies
zip -rq "${repo_root}/e2b-oci-stack.zip" terraform-base
zip -rq "${repo_root}/e2b-oci-cluster.zip" terraform-cluster

echo "Created bundles:"
echo "  e2b-oci-policies.zip"
echo "  e2b-oci-stack.zip"
echo "  e2b-oci-cluster.zip"
echo "Region applied: ${region}"
