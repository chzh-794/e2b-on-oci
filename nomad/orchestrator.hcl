job "orchestrator" {
  type        = "system"
  datacenters = ["ap-osaka-1"]
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
        NODE_ID = "$${node.unique.id}"
      }

      config {
        command = "/bin/bash"
        args    = [
          "-lc",
          "cd /opt/e2b && set -a && source orchestrator.env && set +a && ./bin/orchestrator --port 5008 --proxy-port 5007"
        ]
      }
    }
  }
}
