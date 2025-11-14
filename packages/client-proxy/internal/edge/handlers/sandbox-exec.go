package handlers

import (
	"fmt"
	"net/http"

	"github.com/gin-gonic/gin"
	"go.uber.org/zap"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/e2b-dev/infra/packages/proxy/internal/edge/sandboxes"
	orchestratorpb "github.com/e2b-dev/infra/packages/shared/pkg/grpc/orchestrator"
	api "github.com/e2b-dev/infra/packages/shared/pkg/http/edge"
	"github.com/e2b-dev/infra/packages/shared/pkg/logger"
	"github.com/e2b-dev/infra/packages/shared/pkg/telemetry"
)

func (a *APIStore) V1SandboxExec(c *gin.Context, sandboxID string) {
	ctx := c.Request.Context()

	body, err := parseBody[api.SandboxExecRequest](ctx, c)
	if err != nil {
		a.sendAPIStoreError(c, http.StatusBadRequest, err.Error())
		telemetry.ReportCriticalError(ctx, "error parsing sandbox exec request", err)
		return
	}

	info, err := a.sandboxes.GetSandbox(sandboxID)
	if err != nil {
		if err == sandboxes.ErrSandboxNotFound {
			a.sendAPIStoreError(c, http.StatusNotFound, "Sandbox not found")
			telemetry.ReportError(ctx, "sandbox not found in catalog", err, telemetry.WithSandboxID(sandboxID))
			return
		}

		a.sendAPIStoreError(c, http.StatusInternalServerError, "Failed to resolve sandbox catalog entry")
		telemetry.ReportCriticalError(ctx, "error retrieving sandbox from catalog", err)
		return
	}

	node, ok := a.orchestratorPool.GetOrchestrator(info.OrchestratorId)
	if !ok || node == nil {
		a.sendAPIStoreError(c, http.StatusBadGateway, "Sandbox orchestrator is not reachable")
		reportErr := fmt.Errorf("orchestrator %s unavailable", info.OrchestratorId)
		telemetry.ReportError(ctx, "sandbox orchestrator not found", reportErr, telemetry.WithSandboxID(sandboxID))
		return
	}

	execID := info.ExecutionId
	if body.ExecutionId != nil && *body.ExecutionId != "" {
		execID = *body.ExecutionId
	}

	grpcReq := &orchestratorpb.SandboxExecRequest{
		SandboxId: sandboxID,
		Command:   body.Command,
	}

	if body.Args != nil {
		grpcReq.Args = append(grpcReq.Args, (*body.Args)...)
	}

	if body.Env != nil {
		grpcReq.Env = *body.Env
	}

	if execID != "" {
		grpcReq.ExecutionId = &execID
	}

	if body.Cwd != nil {
		grpcReq.Cwd = body.Cwd
	}

	if body.TimeoutSeconds != nil && *body.TimeoutSeconds > 0 {
		timeout := uint32(*body.TimeoutSeconds)
		grpcReq.TimeoutSeconds = &timeout
	}

	if body.AccessToken != nil && *body.AccessToken != "" {
		grpcReq.AccessToken = body.AccessToken
	}

	grpcResp, err := node.Client.Sandbox.Exec(ctx, grpcReq)
	if err != nil {
		st, ok := status.FromError(err)
		if !ok {
			a.sendAPIStoreError(c, http.StatusInternalServerError, "Unexpected error executing command")
			telemetry.ReportCriticalError(ctx, "sandbox exec error", err, telemetry.WithSandboxID(sandboxID))
			return
		}

		switch st.Code() {
		case codes.NotFound:
			a.sendAPIStoreError(c, http.StatusNotFound, st.Message())
		case codes.PermissionDenied, codes.FailedPrecondition:
			a.sendAPIStoreError(c, http.StatusConflict, st.Message())
		case codes.InvalidArgument:
			a.sendAPIStoreError(c, http.StatusBadRequest, st.Message())
		default:
			a.sendAPIStoreError(c, http.StatusInternalServerError, st.Message())
		}

		telemetry.ReportError(ctx, "sandbox exec rpc error", err, telemetry.WithSandboxID(sandboxID))
		return
	}

	stdout := grpcResp.GetStdout()
	stderr := grpcResp.GetStderr()
	exitCode := grpcResp.GetExitCode()
	statusText := grpcResp.GetStatus()

	telemetry.ReportEvent(ctx, "sandbox exec completed")

	c.JSON(http.StatusOK, api.SandboxExecResponse{
		Stdout:   &stdout,
		Stderr:   &stderr,
		ExitCode: &exitCode,
		Status:   &statusText,
	})

	zap.L().Info("Sandbox exec completed",
		logger.WithSandboxID(sandboxID),
	)
}
