package server

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"time"

	"connectrpc.com/connect"
	"github.com/google/uuid"
	"github.com/launchdarkly/go-sdk-common/v3/ldcontext"
	"go.opentelemetry.io/otel/attribute"
	"go.uber.org/zap"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
	"google.golang.org/protobuf/types/known/timestamppb"

	"github.com/e2b-dev/infra/packages/orchestrator/internal/config"
	"github.com/e2b-dev/infra/packages/orchestrator/internal/sandbox"
	"github.com/e2b-dev/infra/packages/orchestrator/internal/sandbox/build"
	"github.com/e2b-dev/infra/packages/orchestrator/internal/sandbox/fc"
	"github.com/e2b-dev/infra/packages/shared/pkg/consts"
	"github.com/e2b-dev/infra/packages/shared/pkg/env"
	featureflags "github.com/e2b-dev/infra/packages/shared/pkg/feature-flags"
	sharedgrpc "github.com/e2b-dev/infra/packages/shared/pkg/grpc"
	processrpc "github.com/e2b-dev/infra/packages/shared/pkg/grpc/envd/process"
	processconnect "github.com/e2b-dev/infra/packages/shared/pkg/grpc/envd/process/processconnect"
	"github.com/e2b-dev/infra/packages/shared/pkg/grpc/orchestrator"
	"github.com/e2b-dev/infra/packages/shared/pkg/logger"
	sbxlogger "github.com/e2b-dev/infra/packages/shared/pkg/logger/sandbox"
	"github.com/e2b-dev/infra/packages/shared/pkg/storage"
	"github.com/e2b-dev/infra/packages/shared/pkg/telemetry"
)

const (
	requestTimeout = 60 * time.Second
)

func (s *server) Create(ctxConn context.Context, req *orchestrator.SandboxCreateRequest) (*orchestrator.SandboxCreateResponse, error) {
	ctx, cancel := context.WithTimeoutCause(ctxConn, requestTimeout, fmt.Errorf("request timed out"))
	defer cancel()

	childCtx, childSpan := s.tracer.Start(ctx, "sandbox-create")
	defer childSpan.End()

	childSpan.SetAttributes(
		telemetry.WithTemplateID(req.Sandbox.TemplateId),
		attribute.String("kernel.version", req.Sandbox.KernelVersion),
		telemetry.WithSandboxID(req.Sandbox.SandboxId),
		attribute.String("client.id", s.info.ClientId),
		attribute.String("envd.version", req.Sandbox.EnvdVersion),
	)

	// TODO: Temporary workaround, remove API changes deployed
	if req.Sandbox.GetExecutionId() == "" {
		req.Sandbox.ExecutionId = uuid.New().String()
	}

	flagCtx := ldcontext.NewBuilder(featureflags.MetricsWriteFlagName).SetString("sandbox_id", req.Sandbox.SandboxId).Build()
	metricsWriteFlag, flagErr := s.featureFlags.Ld.BoolVariation(featureflags.MetricsWriteFlagName, flagCtx, featureflags.MetricsWriteDefault)
	if flagErr != nil {
		zap.L().Error("soft failing during metrics write feature flag receive", zap.Error(flagErr))
	}

	var sbx *sandbox.Sandbox
	var cleanup *sandbox.Cleanup
	var err error

	// OCI POC: Use snapshot-based boot if Snapshot flag is true, otherwise fresh boot
	if req.Sandbox.Snapshot {
		sbx, cleanup, err = sandbox.ResumeSandbox(
			childCtx,
			s.tracer,
			s.networkPool,
			s.templateCache,
			req.Sandbox,
			childSpan.SpanContext().TraceID().String(),
			req.StartTime.AsTime(),
			req.EndTime.AsTime(),
			req.Sandbox.BaseTemplateId,
			s.devicePool,
			config.AllowSandboxInternet,
			metricsWriteFlag,
		)
	} else {
		// Fresh boot without snapshot (for POC without snapshot files)
		t, getTemplateErr := s.templateCache.GetTemplate(
			req.Sandbox.TemplateId,
			req.Sandbox.BuildId,
			req.Sandbox.KernelVersion,
			req.Sandbox.FirecrackerVersion,
		)
		if getTemplateErr != nil {
			return nil, status.Errorf(codes.Internal, "failed to get template: %s", getTemplateErr)
		}

		// Use empty/default values for fresh boot
		debugVMLogs := env.GetEnv("SANDBOX_DEBUG_VM_LOGS", "false") == "true"
		processOptions := fc.ProcessOptions{
			InitScriptPath:      "/sbin/init", // Fixed: was pointing to .conf file
			KernelLogs:          debugVMLogs,
			SystemdToKernelLogs: debugVMLogs,
			Stdout:              os.Stdout,
			Stderr:              os.Stderr,
		}

		sbx, cleanup, err = sandbox.CreateSandbox(
			childCtx,
			s.tracer,
			s.networkPool,
			s.devicePool,
			req.Sandbox,
			t,
			req.EndTime.AsTime().Sub(req.StartTime.AsTime()),
			"", // Empty = use NBDProvider (production path)
			processOptions,
			config.AllowSandboxInternet,
		)
	}
	if err != nil {
		zap.L().Error("failed to create sandbox, cleaning up", zap.Error(err))
		cleanupErr := cleanup.Run(ctx)

		err := errors.Join(err, context.Cause(ctx), cleanupErr)
		telemetry.ReportCriticalError(ctx, "failed to cleanup sandbox", err)

		return nil, status.Errorf(codes.Internal, "failed to cleanup sandbox: %s", err)
	}

	s.sandboxes.Insert(req.Sandbox.SandboxId, sbx)
	go func() {
		ctx, childSpan := s.tracer.Start(context.Background(), "sandbox-create-stop")
		defer childSpan.End()

		waitErr := sbx.Wait(ctx)
		if waitErr != nil {
			sbxlogger.I(sbx).Error("failed to wait for sandbox, cleaning up", zap.Error(waitErr))
		}

		cleanupErr := cleanup.Run(ctx)
		if cleanupErr != nil {
			sbxlogger.I(sbx).Error("failed to cleanup sandbox, will remove from cache", zap.Error(cleanupErr))
		}

		// Remove the sandbox from cache only if the cleanup IDs match.
		// This prevents us from accidentally removing started sandbox (via resume) from the cache if cleanup is taking longer than the request timeout.
		// This could have caused the "invisible" sandboxes that are not in orchestrator or API, but are still on client.
		s.sandboxes.RemoveCb(req.Sandbox.SandboxId, func(_ string, v *sandbox.Sandbox, exists bool) bool {
			if !exists {
				return false
			}

			if v == nil {
				return false
			}

			return sbx.Config.ExecutionId == v.Config.ExecutionId
		})

		// Remove the proxies assigned to the sandbox from the pool to prevent them from being reused.
		s.proxy.RemoveFromPool(sbx.Config.ExecutionId)

		sbxlogger.E(sbx).Info("Sandbox killed")
	}()

	return &orchestrator.SandboxCreateResponse{
		ClientId: s.info.ClientId,
	}, nil
}

func (s *server) Update(ctx context.Context, req *orchestrator.SandboxUpdateRequest) (*emptypb.Empty, error) {
	ctx, childSpan := s.tracer.Start(ctx, "sandbox-update")
	defer childSpan.End()

	childSpan.SetAttributes(
		telemetry.WithSandboxID(req.SandboxId),
		attribute.String("client.id", s.info.ClientId),
	)

	item, ok := s.sandboxes.Get(req.SandboxId)
	if !ok {
		telemetry.ReportCriticalError(ctx, "sandbox not found", nil)

		return nil, status.Error(codes.NotFound, "sandbox not found")
	}

	item.EndAt = req.EndTime.AsTime()

	return &emptypb.Empty{}, nil
}

func (s *server) List(ctx context.Context, _ *emptypb.Empty) (*orchestrator.SandboxListResponse, error) {
	_, childSpan := s.tracer.Start(ctx, "sandbox-list")
	defer childSpan.End()

	items := s.sandboxes.Items()

	sandboxes := make([]*orchestrator.RunningSandbox, 0, len(items))

	for _, sbx := range items {
		if sbx == nil {
			continue
		}

		if sbx.Config == nil {
			continue
		}

		sandboxes = append(sandboxes, &orchestrator.RunningSandbox{
			Config:    sbx.Config,
			ClientId:  s.info.ClientId,
			StartTime: timestamppb.New(sbx.StartedAt),
			EndTime:   timestamppb.New(sbx.EndAt),
		})
	}

	return &orchestrator.SandboxListResponse{
		Sandboxes: sandboxes,
	}, nil
}

func (s *server) Delete(ctxConn context.Context, in *orchestrator.SandboxDeleteRequest) (*emptypb.Empty, error) {
	ctx, cancel := context.WithTimeoutCause(ctxConn, requestTimeout, fmt.Errorf("request timed out"))
	defer cancel()

	ctx, childSpan := s.tracer.Start(ctx, "sandbox-delete")
	defer childSpan.End()

	childSpan.SetAttributes(
		telemetry.WithSandboxID(in.SandboxId),
		attribute.String("client.id", s.info.ClientId),
	)

	sbx, ok := s.sandboxes.Get(in.SandboxId)
	if !ok {
		telemetry.ReportCriticalError(ctx, "sandbox not found", nil, telemetry.WithSandboxID(in.SandboxId))

		return nil, status.Errorf(codes.NotFound, "sandbox '%s' not found", in.SandboxId)
	}

	// Remove the sandbox from the cache to prevent loading it again in API during the time the instance is stopping.
	// Old comment:
	// 	Ensure the sandbox is removed from cache.
	// 	Ideally we would rely only on the goroutine defer.
	// Don't allow connecting to the sandbox anymore.
	s.sandboxes.Remove(in.SandboxId)

	// Check health metrics before stopping the sandbox
	sbx.Checks.Healthcheck(true)

	err := sbx.Stop(ctx)
	if err != nil {
		sbxlogger.I(sbx).Error("error stopping sandbox", logger.WithSandboxID(in.SandboxId), zap.Error(err))
	}

	return &emptypb.Empty{}, nil
}

func (s *server) Pause(ctx context.Context, in *orchestrator.SandboxPauseRequest) (*emptypb.Empty, error) {
	ctx, childSpan := s.tracer.Start(ctx, "sandbox-pause")
	defer childSpan.End()

	s.pauseMu.Lock()

	sbx, ok := s.sandboxes.Get(in.SandboxId)
	if !ok {
		s.pauseMu.Unlock()

		telemetry.ReportCriticalError(ctx, "sandbox not found", nil)

		return nil, status.Error(codes.NotFound, "sandbox not found")
	}

	s.sandboxes.Remove(in.SandboxId)

	s.pauseMu.Unlock()

	snapshotTemplateFiles, err := storage.NewTemplateFiles(
		in.TemplateId,
		in.BuildId,
		sbx.Config.KernelVersion,
		sbx.Config.FirecrackerVersion,
	).NewTemplateCacheFiles()
	if err != nil {
		telemetry.ReportCriticalError(ctx, "error creating template files", err)

		return nil, status.Errorf(codes.Internal, "error creating template files: %s", err)
	}

	defer func() {
		// sbx.Stop sometimes blocks for several seconds,
		// so we don't want to block the request and do the cleanup in a goroutine after we already removed sandbox from cache and proxy.
		go func() {
			ctx, childSpan := s.tracer.Start(context.Background(), "sandbox-pause-stop")
			defer childSpan.End()

			err := sbx.Stop(ctx)
			if err != nil {
				sbxlogger.I(sbx).Error("error stopping sandbox after snapshot", logger.WithSandboxID(in.SandboxId), zap.Error(err))
			}
		}()
	}()

	snapshot, err := sbx.Pause(ctx, s.tracer, snapshotTemplateFiles)
	if err != nil {
		telemetry.ReportCriticalError(ctx, "error snapshotting sandbox", err, telemetry.WithSandboxID(in.SandboxId))

		return nil, status.Errorf(codes.Internal, "error snapshotting sandbox '%s': %s", in.SandboxId, err)
	}

	err = s.templateCache.AddSnapshot(
		snapshotTemplateFiles.TemplateId,
		snapshotTemplateFiles.BuildId,
		snapshotTemplateFiles.KernelVersion,
		snapshotTemplateFiles.FirecrackerVersion,
		snapshot.MemfileDiffHeader,
		snapshot.RootfsDiffHeader,
		snapshot.Snapfile,
		snapshot.MemfileDiff,
		snapshot.RootfsDiff,
	)
	if err != nil {
		telemetry.ReportCriticalError(ctx, "error adding snapshot to template cache", err)

		return nil, status.Errorf(codes.Internal, "error adding snapshot to template cache: %s", err)
	}

	telemetry.ReportEvent(ctx, "added snapshot to template cache")

	go func() {
		var memfilePath *string

		switch r := snapshot.MemfileDiff.(type) {
		case *build.NoDiff:
			break
		default:
			memfileLocalPath, err := r.CachePath()
			if err != nil {
				sbxlogger.I(sbx).Error("error getting memfile diff path", zap.Error(err))

				return
			}

			memfilePath = &memfileLocalPath
		}

		var rootfsPath *string

		switch r := snapshot.RootfsDiff.(type) {
		case *build.NoDiff:
			break
		default:
			rootfsLocalPath, err := r.CachePath()
			if err != nil {
				sbxlogger.I(sbx).Error("error getting rootfs diff path", zap.Error(err))

				return
			}

			rootfsPath = &rootfsLocalPath
		}

		b := storage.NewTemplateBuild(
			snapshot.MemfileDiffHeader,
			snapshot.RootfsDiffHeader,
			s.persistence,
			snapshotTemplateFiles.TemplateFiles,
		)

		err = <-b.Upload(
			context.Background(),
			snapshot.Snapfile.Path(),
			memfilePath,
			rootfsPath,
		)
		if err != nil {
			sbxlogger.I(sbx).Error("error uploading sandbox snapshot", zap.Error(err))

			return
		}
	}()

	return &emptypb.Empty{}, nil
}

func (s *server) Exec(ctx context.Context, req *orchestrator.SandboxExecRequest) (*orchestrator.SandboxExecResponse, error) {
	ctx, span := s.tracer.Start(ctx, "sandbox-exec")
	defer span.End()

	telemetry.SetAttributes(ctx, telemetry.WithSandboxID(req.GetSandboxId()))

	// DETAILED LOGGING: Log exec request start (also to stderr for debugging)
	zap.L().Info("Exec request received",
		zap.String("sandbox_id", req.GetSandboxId()),
		zap.String("command", req.GetCommand()),
		zap.Strings("args", req.GetArgs()),
		zap.Uint32("timeout_seconds", func() uint32 {
			if req.TimeoutSeconds != nil {
				return *req.TimeoutSeconds
			}
			return 0
		}()),
	)
	// Also log to stderr for immediate visibility
	fmt.Fprintf(os.Stderr, "[ORCHESTRATOR] Exec request: sandbox=%s command=%s args=%v\n",
		req.GetSandboxId(), req.GetCommand(), req.GetArgs())

	if req.GetSandboxId() == "" {
		return nil, status.Error(codes.InvalidArgument, "sandbox_id is required")
	}

	if req.GetCommand() == "" {
		return nil, status.Error(codes.InvalidArgument, "command is required")
	}

	sbx, ok := s.sandboxes.Get(req.GetSandboxId())
	if !ok || sbx == nil {
		return nil, status.Errorf(codes.NotFound, "sandbox '%s' not found", req.GetSandboxId())
	}

	if execID := req.GetExecutionId(); execID != "" && sbx.Config != nil && sbx.Config.ExecutionId != execID {
		return nil, status.Error(codes.PermissionDenied, "execution id does not match active sandbox session")
	}

	slot := sbx.Slot
	if slot == nil {
		return nil, status.Errorf(codes.FailedPrecondition, "sandbox '%s' network slot unavailable", req.GetSandboxId())
	}

	baseURL := fmt.Sprintf("http://%s:%d", slot.HostIPString(), consts.DefaultEnvdServerPort)

	httpClient := &http.Client{}

	// Apply default timeout if not specified (60 seconds should be enough for most commands)
	// This prevents infinite hangs if the stream doesn't close or End event is never sent
	var cancel context.CancelFunc
	if req.TimeoutSeconds != nil && req.GetTimeoutSeconds() > 0 {
		timeout := time.Duration(req.GetTimeoutSeconds()) * time.Second
		ctx, cancel = context.WithTimeout(ctx, timeout)
		defer cancel()
	} else {
		// Default timeout: 60 seconds
		defaultTimeout := 60 * time.Second
		ctx, cancel = context.WithTimeout(ctx, defaultTimeout)
		defer cancel()
	}

	processClient := processconnect.NewProcessClient(httpClient, baseURL)

	processCfg := &processrpc.ProcessConfig{
		Cmd:  req.GetCommand(),
		Args: req.GetArgs(),
		Envs: req.GetEnv(),
	}

	if cwd := req.GetCwd(); cwd != "" {
		processCfg.Cwd = &cwd
	}

	startReq := connect.NewRequest(&processrpc.StartRequest{
		Process: processCfg,
	})

	if err := sharedgrpc.SetSandboxHeader(startReq.Header(), baseURL, req.GetSandboxId()); err != nil {
		return nil, status.Errorf(codes.Internal, "failed to set sandbox header: %v", err)
	}

	sharedgrpc.SetUserHeader(startReq.Header(), "root")

	switch {
	case req.GetAccessToken() != "":
		startReq.Header().Set("X-Access-Token", req.GetAccessToken())
	case sbx.Config != nil && sbx.Config.EnvdAccessToken != nil:
		startReq.Header().Set("X-Access-Token", *sbx.Config.EnvdAccessToken)
	}

	// DETAILED LOGGING: Log before starting process stream
	zap.L().Info("Starting process stream",
		zap.String("sandbox_id", req.GetSandboxId()),
		zap.String("command", req.GetCommand()),
		zap.String("base_url", baseURL),
	)

	stream, err := processClient.Start(ctx, startReq)
	if err != nil {
		zap.L().Error("Failed to start process stream",
			zap.String("sandbox_id", req.GetSandboxId()),
			zap.String("command", req.GetCommand()),
			zap.String("base_url", baseURL),
			zap.Error(err),
		)
		return nil, status.Errorf(codes.Internal, "failed to start process: %v", err)
	}
	defer stream.Close()

	zap.L().Info("Process stream started, converting to channels",
		zap.String("sandbox_id", req.GetSandboxId()),
		zap.String("command", req.GetCommand()),
	)
	fmt.Fprintf(os.Stderr, "[ORCHESTRATOR] Process stream started: sandbox=%s command=%s\n",
		req.GetSandboxId(), req.GetCommand())

	msgCh, errCh := sharedgrpc.StreamToChannel(ctx, stream)
	fmt.Fprintf(os.Stderr, "[ORCHESTRATOR] StreamToChannel returned, entering event loop\n")

	var stdoutBuf bytes.Buffer
	var stderrBuf bytes.Buffer
	var exitCode int32
	statusText := ""

	zap.L().Info("Entering exec event loop",
		zap.String("sandbox_id", req.GetSandboxId()),
		zap.String("command", req.GetCommand()),
	)
	fmt.Fprintf(os.Stderr, "[ORCHESTRATOR] Entering exec event loop: sandbox=%s command=%s\n",
		req.GetSandboxId(), req.GetCommand())

	loopIteration := 0
	for {
		loopIteration++
		if loopIteration%100 == 0 {
			fmt.Fprintf(os.Stderr, "[ORCHESTRATOR] Event loop iteration %d: sandbox=%s command=%s\n",
				loopIteration, req.GetSandboxId(), req.GetCommand())
		}
		select {
		case <-ctx.Done():
			zap.L().Warn("Exec context cancelled/timeout",
				zap.String("sandbox_id", req.GetSandboxId()),
				zap.String("command", req.GetCommand()),
				zap.Error(ctx.Err()),
				zap.String("stdout_so_far", stdoutBuf.String()),
				zap.String("stderr_so_far", stderrBuf.String()),
			)
			return nil, status.Errorf(codes.DeadlineExceeded, "sandbox exec cancelled: %v", ctx.Err())
		case streamErr, ok := <-errCh:
			if ok && streamErr != nil {
				zap.L().Error("Stream error received",
					zap.String("sandbox_id", req.GetSandboxId()),
					zap.String("command", req.GetCommand()),
					zap.Error(streamErr),
				)
				return nil, status.Errorf(codes.Internal, "stream error: %v", streamErr)
			}
			zap.L().Info("Error channel closed",
				zap.String("sandbox_id", req.GetSandboxId()),
				zap.String("command", req.GetCommand()),
			)
			errCh = nil
			if msgCh == nil {
				zap.L().Info("Both channels closed, exiting loop",
					zap.String("sandbox_id", req.GetSandboxId()),
					zap.String("command", req.GetCommand()),
				)
				goto DONE
			}
		case msg, ok := <-msgCh:
			if !ok {
				zap.L().Info("Message channel closed",
					zap.String("sandbox_id", req.GetSandboxId()),
					zap.String("command", req.GetCommand()),
					zap.String("stdout_so_far", stdoutBuf.String()),
					zap.String("stderr_so_far", stderrBuf.String()),
					zap.Int32("exit_code", exitCode),
				)
				fmt.Fprintf(os.Stderr, "[ORCHESTRATOR] Message channel closed: sandbox=%s command=%s stdout=%s exit_code=%d\n",
					req.GetSandboxId(), req.GetCommand(), stdoutBuf.String(), exitCode)
				msgCh = nil
				if errCh == nil {
					zap.L().Info("Both channels closed, exiting loop",
						zap.String("sandbox_id", req.GetSandboxId()),
						zap.String("command", req.GetCommand()),
					)
					fmt.Fprintf(os.Stderr, "[ORCHESTRATOR] Both channels closed, exiting loop\n")
					goto DONE
				}
				continue
			}
			fmt.Fprintf(os.Stderr, "[ORCHESTRATOR] Received message: sandbox=%s command=%s\n",
				req.GetSandboxId(), req.GetCommand())

			event := msg.GetEvent()
			if event == nil {
				zap.L().Warn("Received nil event",
					zap.String("sandbox_id", req.GetSandboxId()),
					zap.String("command", req.GetCommand()),
				)
				continue
			}

			switch {
			case event.GetData() != nil:
				data := event.GetData()
				if out := data.GetStdout(); len(out) > 0 {
					stdoutBuf.Write(out)
					zap.L().Debug("Received stdout data",
						zap.String("sandbox_id", req.GetSandboxId()),
						zap.String("command", req.GetCommand()),
						zap.String("data", string(out)),
					)
				}
				if errBytes := data.GetStderr(); len(errBytes) > 0 {
					stderrBuf.Write(errBytes)
					zap.L().Debug("Received stderr data",
						zap.String("sandbox_id", req.GetSandboxId()),
						zap.String("command", req.GetCommand()),
						zap.String("data", string(errBytes)),
					)
				}
			case event.GetEnd() != nil:
				end := event.GetEnd()
				exitCode = end.GetExitCode()
				statusText = end.GetStatus()
				if errMsg := end.GetError(); errMsg != "" {
					if statusText != "" {
						statusText = fmt.Sprintf("%s: %s", statusText, errMsg)
					} else {
						statusText = errMsg
					}
				}
				zap.L().Info("Received End event - process completed",
					zap.String("sandbox_id", req.GetSandboxId()),
					zap.String("command", req.GetCommand()),
					zap.Int32("exit_code", exitCode),
					zap.String("status", statusText),
					zap.String("stdout", stdoutBuf.String()),
					zap.String("stderr", stderrBuf.String()),
				)
				// Also log to stderr for immediate visibility
				fmt.Fprintf(os.Stderr, "[ORCHESTRATOR] End event received: sandbox=%s command=%s exit_code=%d stdout=%s\n",
					req.GetSandboxId(), req.GetCommand(), exitCode, stdoutBuf.String())
				// End event received - process has completed
				// Exit immediately instead of waiting for stream to close
				// The stream may not close immediately, causing infinite wait
				fmt.Fprintf(os.Stderr, "[ORCHESTRATOR] Exiting exec loop after End event\n")
				goto DONE
			default:
				zap.L().Debug("Received other event type",
					zap.String("sandbox_id", req.GetSandboxId()),
					zap.String("command", req.GetCommand()),
					zap.String("event_type", fmt.Sprintf("%T", event)),
				)
				// ignore other events (start, keepalive, etc.)
			}
		}
	}

DONE:
	zap.L().Info("Exec completed",
		zap.String("sandbox_id", req.GetSandboxId()),
		zap.String("command", req.GetCommand()),
		zap.Int32("exit_code", exitCode),
		zap.String("status", statusText),
		zap.String("stdout", stdoutBuf.String()),
		zap.String("stderr", stderrBuf.String()),
	)
	return &orchestrator.SandboxExecResponse{
		Stdout:   stdoutBuf.String(),
		Stderr:   stderrBuf.String(),
		ExitCode: exitCode,
		Status:   statusText,
	}, nil
}
