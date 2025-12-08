job "orchestrator" {
  type        = "system"
  datacenters = ["__REGION__"]
  priority    = 90

  constraint {
    attribute = "${node.class}"
    value     = "client"
  }

  group "client-orchestrator" {
    network {
      port "orchestrator" {
        static = 5008
      }
      port "proxy" {
        static = 5007
      }
    }

    service {
      name = "orchestrator"
      port = "orchestrator"

      check {
        type         = "tcp"
        name         = "health"
        interval     = "20s"
        timeout      = "5s"
        port         = "orchestrator"
      }
    }

    task "orchestrator" {
      driver = "raw_exec"
      # user = "root"  # Removed: AWS doesn't specify user, let it default to Nomad agent user

      resources {
        memory = 2048
        cpu    = 1000
      }

      env {
        NODE_ID                      = "$${node.unique.id}"
        STORAGE_PROVIDER             = "OCIBucket"
        TEMPLATE_BUCKET_NAME         = "fc-template"
        OCI_REGION                   = "us-ashburn-1"
        OCI_NAMESPACE                = "replace-with-namespace"
        ARTIFACTS_REGISTRY_PROVIDER  = "OCI_OCIR"
        OCI_CONTAINER_REPOSITORY_NAME = "e2b-templates"
      }

      config {
        command = "/opt/e2b/bin/orchestrator-wrapper.sh"
        args    = []
      }
    }
  }
}
