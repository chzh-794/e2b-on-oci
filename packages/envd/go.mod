module github.com/e2b-dev/infra/packages/envd

go 1.24.3

require (
	connectrpc.com/authn v0.1.0
	connectrpc.com/connect v1.18.1
	connectrpc.com/cors v0.1.0
	github.com/creack/pty v1.1.23
	github.com/e2b-dev/fsnotify v0.0.0-20241216145137-2fe5d32bcb51
	github.com/e2b-dev/infra/packages/shared v0.0.0
	github.com/go-chi/chi/v5 v5.2.2
	github.com/oapi-codegen/runtime v1.1.1
	github.com/rs/cors v1.11.1
	github.com/rs/zerolog v1.34.0
	github.com/shirou/gopsutil/v4 v4.24.10
	github.com/stretchr/testify v1.10.0
	google.golang.org/protobuf v1.36.6
)

require (
	github.com/apapsch/go-jsonmerge/v2 v2.0.0 // indirect
	github.com/davecgh/go-spew v1.1.2-0.20180830191138-d8f796af33cc // indirect
	github.com/dchest/uniuri v1.2.0 // indirect
	github.com/ebitengine/purego v0.8.1 // indirect
	github.com/go-ole/go-ole v1.3.0 // indirect
	github.com/google/uuid v1.6.0 // indirect
	github.com/kr/pretty v0.3.1 // indirect
	github.com/lufia/plan9stats v0.0.0-20240909124753-873cd0166683 // indirect
	github.com/mattn/go-colorable v0.1.14 // indirect
	github.com/mattn/go-isatty v0.0.20 // indirect
	github.com/pmezard/go-difflib v1.0.1-0.20181226105442-5d4384ee4fb2 // indirect
	github.com/power-devops/perfstat v0.0.0-20240221224432-82ca36839d55 // indirect
	github.com/rogpeppe/go-internal v1.13.1 // indirect
	github.com/tklauser/go-sysconf v0.3.14 // indirect
	github.com/tklauser/numcpus v0.9.0 // indirect
	github.com/yusufpapurcu/wmi v1.2.4 // indirect
	golang.org/x/sys v0.33.0 // indirect
	gopkg.in/check.v1 v1.0.0-20201130134442-10cb98267c6c // indirect
	gopkg.in/yaml.v3 v3.0.1 // indirect
)

replace github.com/e2b-dev/infra/packages/shared v0.0.0 => ../shared
