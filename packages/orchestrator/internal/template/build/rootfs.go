package build

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"math"
	"os"

	"github.com/dustin/go-humanize"
	containerregistry "github.com/google/go-containerregistry/pkg/v1"
	"github.com/google/go-containerregistry/pkg/v1/mutate"
	"go.opentelemetry.io/otel/trace"
	"go.uber.org/zap"

	"github.com/e2b-dev/infra/packages/orchestrator/internal/template/build/ext4"
	"github.com/e2b-dev/infra/packages/orchestrator/internal/template/build/oci"
	"github.com/e2b-dev/infra/packages/orchestrator/internal/template/build/writer"
	artifactsregistry "github.com/e2b-dev/infra/packages/shared/pkg/artifacts-registry"
	"github.com/e2b-dev/infra/packages/shared/pkg/consts"
	"github.com/e2b-dev/infra/packages/shared/pkg/storage"
	"github.com/e2b-dev/infra/packages/shared/pkg/telemetry"
)

const (
	ToMBShift = 20
	// Max size of the rootfs file in MB.
	maxRootfsSize = 15000 << ToMBShift

	rootfsBuildFileName = "rootfs.ext4.build"
	rootfsProvisionLink = "rootfs.ext4.build.provision"

	// provisionScriptFileName is a path where the provision script stores it's exit code.
	provisionScriptResultPath = "/provision.result"
	logExternalPrefix         = "[external] "

	busyBoxBinaryPath = "/bin/busybox"
	busyBoxInitPath   = "usr/bin/init"
	systemdInitPath   = "/sbin/init"
)

type Rootfs struct {
	template         *TemplateConfig
	artifactRegistry artifactsregistry.ArtifactsRegistry
}

type MultiWriter struct {
	writers []io.Writer
}

func (mw *MultiWriter) Write(p []byte) (int, error) {
	for _, writer := range mw.writers {
		_, err := writer.Write(p)
		if err != nil {
			return 0, err
		}
	}

	return len(p), nil
}

func NewRootfs(artifactRegistry artifactsregistry.ArtifactsRegistry, template *TemplateConfig) *Rootfs {
	return &Rootfs{
		template:         template,
		artifactRegistry: artifactRegistry,
	}
}

func (r *Rootfs) createExt4Filesystem(ctx context.Context, tracer trace.Tracer, postProcessor *writer.PostProcessor, rootfsPath string) (c containerregistry.Config, e error) {
	childCtx, childSpan := tracer.Start(ctx, "create-ext4-file")
	defer childSpan.End()

	defer func() {
		if e != nil {
			telemetry.ReportCriticalError(childCtx, "failed to create ext4 filesystem", e)
		}
	}()

	postProcessor.WriteMsg("Requesting Docker Image")

	img, err := oci.GetImage(childCtx, tracer, r.artifactRegistry, r.template.TemplateId, r.template.BuildId)
	if err != nil {
		return containerregistry.Config{}, fmt.Errorf("error requesting docker image: %w", err)
	}

	imageSize, err := oci.GetImageSize(img)
	if err != nil {
		return containerregistry.Config{}, fmt.Errorf("error getting image size: %w", err)
	}
	postProcessor.WriteMsg(fmt.Sprintf("Docker image size: %s", humanize.Bytes(uint64(imageSize))))

	postProcessor.WriteMsg("Setting up system files")
	layers, err := additionalOCILayers(childCtx, r.template)
	if err != nil {
		return containerregistry.Config{}, fmt.Errorf("error populating filesystem: %w", err)
	}
	img, err = mutate.AppendLayers(img, layers...)
	if err != nil {
		return containerregistry.Config{}, fmt.Errorf("error appending layers: %w", err)
	}
	telemetry.ReportEvent(childCtx, "set up filesystem")

	postProcessor.WriteMsg("Creating file system and pulling Docker image")
	ext4Size, err := oci.ToExt4(ctx, tracer, postProcessor, img, rootfsPath, maxRootfsSize, r.template.RootfsBlockSize())
	if err != nil {
		return containerregistry.Config{}, fmt.Errorf("error creating ext4 filesystem: %w", err)
	}
	r.template.rootfsSize = ext4Size
	telemetry.ReportEvent(childCtx, "created rootfs ext4 file")

	postProcessor.WriteMsg("Filesystem cleanup")
	// Make rootfs writable, be default it's readonly
	err = ext4.MakeWritable(ctx, tracer, rootfsPath)
	if err != nil {
		return containerregistry.Config{}, fmt.Errorf("error making rootfs file writable: %w", err)
	}

	// Resize rootfs
	rootfsFreeSpace, err := ext4.GetFreeSpace(ctx, tracer, rootfsPath, r.template.RootfsBlockSize())
	if err != nil {
		return containerregistry.Config{}, fmt.Errorf("error getting free space: %w", err)
	}
	// We need to remove the remaining free space from the ext4 file size
	// This is a residual space that could not be shrunk when creating the filesystem,
	// but is still available for use
	diskAdd := r.template.DiskSizeMB<<ToMBShift - rootfsFreeSpace
	zap.L().Debug("adding disk size diff to rootfs",
		zap.Int64("size_current", ext4Size),
		zap.Int64("size_add", diskAdd),
		zap.Int64("size_free", rootfsFreeSpace),
	)
	if diskAdd > 0 {
		rootfsFinalSize, err := ext4.Enlarge(ctx, tracer, rootfsPath, diskAdd)
		if err != nil {
			return containerregistry.Config{}, fmt.Errorf("error enlarging rootfs: %w", err)
		}
		r.template.rootfsSize = rootfsFinalSize
	}

	// Check the rootfs filesystem corruption
	ext4Check, err := ext4.CheckIntegrity(rootfsPath, true)
	zap.L().Debug("filesystem ext4 integrity",
		zap.String("result", ext4Check),
		zap.Error(err),
	)
	if err != nil {
		return containerregistry.Config{}, fmt.Errorf("error checking ext4 filesystem integrity: %w", err)
	}

	config, err := img.ConfigFile()
	if err != nil {
		return containerregistry.Config{}, fmt.Errorf("error getting image config file: %w", err)
	}

	return config.Config, nil
}

func additionalOCILayers(
	ctx context.Context,
	config *TemplateConfig,
) ([]containerregistry.Layer, error) {
	var scriptDef bytes.Buffer
	err := ProvisionScriptTemplate.Execute(&scriptDef, struct {
		ResultPath string
	}{
		ResultPath: provisionScriptResultPath,
	})
	if err != nil {
		return nil, fmt.Errorf("error executing provision script: %w", err)
	}
	telemetry.ReportEvent(ctx, "executed provision script env")

	memoryLimit := int(math.Min(float64(config.MemoryMB)/2, 512))
	envdWrapperScript := fmt.Sprintf(`#!/usr/bin/env bash
set -euo pipefail

PORT=${ENVD_PORT:-%[1]d}
READY_FILE=/run/envd.ready
LOG_DUP=/var/log/envd.log

mkdir -p /run /var/log /run/envd
ln -sf "$LOG_DUP" /run/envd/envd.log
touch "$LOG_DUP"
chmod 0644 "$LOG_DUP"

if [ -w /dev/console ]; then
  exec > >(tee -a "$LOG_DUP" | tee /dev/console) 2>&1
else
  exec > >(tee -a "$LOG_DUP") 2>&1
fi

echo "[envd-wrapper] starting at $(date -Iseconds) with port ${PORT}"
rm -f "$READY_FILE"
sync

echo "[envd-wrapper] kernel: $(uname -a)"
if command -v ip >/dev/null 2>&1; then
  echo "[envd-wrapper] ip addr:"
  ip addr show
  echo "[envd-wrapper] ip route:"
  ip route show || true
else
  echo "[envd-wrapper] ip command not present"
fi
if command -v networkctl >/dev/null 2>&1; then
  echo "[envd-wrapper] networkctl status:"
  networkctl status --no-pager || true
fi
if ls /sys/class/net >/dev/null 2>&1; then
  echo "[envd-wrapper] interfaces:"
  ls -1 /sys/class/net || true
fi
sync

check_port_busy() {
  if command -v ss >/dev/null 2>&1; then
    ss -H -tln | grep -q ":${PORT} "
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tnl | grep -q ":${PORT} "
  else
    return 1
  fi
}

dump_sockets() {
  if command -v ss >/dev/null 2>&1; then
    ss -tln
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tnl
  else
    echo "[envd-wrapper] neither ss nor netstat available"
  fi
}

echo "[envd-wrapper] existing sockets:"
dump_sockets
sync

stdbuf -oL -eL /usr/bin/envd --debug -port "${PORT}" &
ENVD_PID=$!
echo "[envd-wrapper] envd pid ${ENVD_PID}"

term_handler() {
  echo "[envd-wrapper] received termination signal"
  if kill -0 "$ENVD_PID" 2>/dev/null; then
    kill "$ENVD_PID"
  fi
}
trap term_handler TERM INT

ready_announced=false
for attempt in $(seq 1 200); do
  if ! kill -0 "$ENVD_PID" 2>/dev/null; then
    echo "[envd-wrapper] envd exited before ready (attempt ${attempt})"
    break
  fi
  if check_port_busy; then
    if [ "$ready_announced" = false ]; then
      date -Iseconds >"$READY_FILE"
      echo "[envd-wrapper] envd listening on port ${PORT}, ready file created"
      ready_announced=true
    fi
    break
  fi
  sleep 0.1
done

if [ "$ready_announced" = false ]; then
  echo "[envd-wrapper] envd did not report readiness within wait loop"
fi

wait "$ENVD_PID"
ENVD_EXIT=$?
echo "[envd-wrapper] envd exited with code ${ENVD_EXIT}"
sync
exit "$ENVD_EXIT"
`, consts.DefaultEnvdServerPort)

	journaldPersistentConfig := `[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=64M
SystemKeepFree=16M
RuntimeMaxUse=16M
`

	envdService := fmt.Sprintf(`[Unit]
Description=Env Daemon Service
After=network-online.target multi-user.target
Wants=network-online.target

[Service]
Type=simple
Restart=always
User=root
Group=root
Environment=GOTRACEBACK=all
LimitCORE=infinity
ExecStartPre=/bin/bash -l -c "rm -f /run/envd.ready"
ExecStart=/usr/local/bin/envd-wrapper.sh
Environment="ENVD_PORT=%d"
StandardOutput=journal
StandardError=journal
OOMPolicy=continue
OOMScoreAdjust=-1000
Environment="GOMEMLIMIT=%dMiB"

[Install]
WantedBy=multi-user.target
`, consts.DefaultEnvdServerPort, memoryLimit)

	autologinService := `[Service]
ExecStart=
ExecStart=-/sbin/agetty --noissue --autologin root %I 115200,38400,9600 vt102
`

	rcSScript := `#!/usr/bin/busybox ash
echo "Mounting essential filesystems"
mkdir -p /proc /sys /dev /tmp /run /var/log /var/log/journal
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev
mount -t tmpfs tmpfs /tmp
mount -t tmpfs tmpfs /run
mount -t tmpfs tmpfs /var/log

if command -v systemd-tmpfiles >/dev/null 2>&1; then
  systemd-tmpfiles --create || true
fi

echo "System Init"`

	hostname := "e2b.local"

	hosts := fmt.Sprintf(`127.0.0.1	localhost
::1	localhost ip6-localhost ip6-loopback
fe00::	ip6-localnet
ff00::	ip6-mcastprefix
ff02::1	ip6-allnodes
ff02::2	ip6-allrouters
127.0.1.1	%s
`, hostname)

	e2bFile := fmt.Sprintf(`ENV_ID=%s
BUILD_ID=%s
`, config.TemplateId, config.BuildId)

	envdFileData, err := os.ReadFile(storage.HostEnvdPath)
	if err != nil {
		return nil, fmt.Errorf("error reading envd file: %w", err)
	}

	busyBox, err := os.ReadFile(busyBoxBinaryPath)
	if err != nil {
		return nil, fmt.Errorf("error reading busybox binary: %w", err)
	}

	filesLayer, err := LayerFile(
		map[string]layerFile{
			// Setup system
			"etc/hostname":    {[]byte(hostname), 0o644},
			"etc/hosts":       {[]byte(hosts), 0o644},
			"etc/resolv.conf": {[]byte("nameserver 8.8.8.8"), 0o644},

			".e2b":                            {[]byte(e2bFile), 0o644},
			storage.GuestEnvdPath:             {envdFileData, 0o777},
			"etc/systemd/system/envd.service": {[]byte(envdService), 0o644},
			"etc/systemd/journald.conf.d/persistent.conf":                    {[]byte(journaldPersistentConfig), 0o644},
			"usr/local/bin/envd-wrapper.sh":                                  {[]byte(envdWrapperScript), 0o755},
			"etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf": {[]byte(autologinService), 0o644},

			// Provision script
			"usr/local/bin/provision.sh": {scriptDef.Bytes(), 0o777},
			// Setup init system
			"usr/bin/busybox": {busyBox, 0o755},
			// Set to bin/init so it's not in conflict with systemd
			// Any rewrite of the init file when booted from it will corrupt the filesystem
			busyBoxInitPath:  {busyBox, 0o755},
			"etc/init.d/rcS": {[]byte(rcSScript), 0o777},
			"etc/inittab": {[]byte(fmt.Sprintf(`# Run system init
::sysinit:/etc/init.d/rcS

# Run the provision script, prefix the output with a log prefix
::wait:/bin/sh -c '/usr/local/bin/provision.sh 2>&1 | sed "s/^/%s/"'

# Reboot the system after the script
# Running the poweroff or halt commands inside a Linux guest will bring it down but Firecracker process remains unaware of the guest shutdown so it lives on.
# Running the reboot command in a Linux guest will gracefully bring down the guest system and also bring a graceful end to the Firecracker process.
::once:/usr/bin/busybox reboot

# Clean shutdown of filesystems and swap
::shutdown:/usr/bin/busybox swapoff -a
::shutdown:/usr/bin/busybox umount -a -r -v
`, logExternalPrefix)), 0o777},
		},
	)
	if err != nil {
		return nil, fmt.Errorf("error creating layer from files: %w", err)
	}

	symlinkLayer, err := LayerSymlink(
		map[string]string{
			// Enable envd service autostart
			"etc/systemd/system/multi-user.target.wants/envd.service": "etc/systemd/system/envd.service",
			// Enable chrony service autostart
			"etc/systemd/system/multi-user.target.wants/chrony.service": "etc/systemd/system/chrony.service",
		},
	)
	if err != nil {
		return nil, fmt.Errorf("error creating layer from symlinks: %w", err)
	}

	return []containerregistry.Layer{
		filesLayer,
		symlinkLayer,
	}, nil
}
