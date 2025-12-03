job "template-manager" {
  datacenters = ["us-ashburn-1"]
  type        = "service"
  priority    = 70
  meta = {
    storage_mode = "local"
  }

  reschedule {
    attempts  = 3
    interval  = "45s"
    delay     = "5s"
    max_delay = "2m"
    unlimited = false
  }

  constraint {
    attribute = "${node.class}"
    value     = "client"
  }

  group "template-manager" {
    network {
      port "template" {
        static = 5009
      }
      port "proxy" {
        static = 15007
      }
    }

    service {
      name = "template-manager"
      port = "template"
    }

    task "template-manager" {
      driver = "raw_exec"
      # user = "root"  # Removed: AWS doesn't specify user, let it default to Nomad agent user

      resources {
        memory = 4096
        cpu    = 1000
      }

      env {
        NODE_ID                          = "$${node.unique.id}"
        STORAGE_PROVIDER                 = "OCIBucket"
        LOCAL_TEMPLATE_STORAGE_BASE_PATH = "/var/e2b/templates"
        TEMPLATE_BUCKET_NAME             = "${oci_bucket_name}"
        ARTIFACTS_REGISTRY_PROVIDER      = "Local"
        SANDBOX_DEBUG_VM_LOGS            = "true"
        OCI_REGION                       = "${oci_region}"
        OCI_NAMESPACE                    = "${oci_namespace}"
      }

      config {
        command = "/bin/bash"
        args    = [
          "-lc",
          "cd /opt/e2b && export NODE_ID=\"${NODE_ID}\" && set -a && source template-manager.env && set +a && ./bin/template-manager --port 5009 --proxy-port 15007"
        ]
      }
    }
  }
}
