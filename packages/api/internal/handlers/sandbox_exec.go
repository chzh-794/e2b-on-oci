package handlers

import (
	"fmt"
	"net/http"

	"github.com/gin-gonic/gin"
	"go.uber.org/zap"

	"github.com/e2b-dev/infra/packages/api/internal/api"
	"github.com/e2b-dev/infra/packages/api/internal/auth"
	authcache "github.com/e2b-dev/infra/packages/api/internal/cache/auth"
	"github.com/e2b-dev/infra/packages/api/internal/cache/instance"
	"github.com/e2b-dev/infra/packages/api/internal/utils"
	edgeapi "github.com/e2b-dev/infra/packages/shared/pkg/http/edge"
	"github.com/e2b-dev/infra/packages/shared/pkg/logger"
	"github.com/e2b-dev/infra/packages/shared/pkg/telemetry"
)

func (a *APIStore) PostSandboxesSandboxIDExec(c *gin.Context, sandboxID string) {
	ctx := c.Request.Context()
	requestedSandboxID := utils.ShortID(sandboxID)

	teamInfoValue, ok := c.Value(auth.TeamContextKey).(authcache.AuthTeamInfo)
	if !ok {
		a.sendAPIStoreError(c, http.StatusUnauthorized, "Missing team authentication")
		telemetry.ReportCriticalError(ctx, "sandbox exec missing team context", fmt.Errorf("team context not set"))
		return
	}
	teamInfo := teamInfoValue
	teamID := teamInfo.Team.ID

	body, err := utils.ParseBody[api.SandboxExecRequest](ctx, c)
	if err != nil {
		a.sendAPIStoreError(c, http.StatusBadRequest, err.Error())
		telemetry.ReportCriticalError(ctx, "error parsing sandbox exec request", err)
		return
	}

	runningSandboxes := a.orchestrator.GetSandboxes(ctx, &teamID)
	sbx := findSandboxByID(runningSandboxes, sandboxID, requestedSandboxID)
	if sbx == nil {
		a.sendAPIStoreError(c, http.StatusNotFound, "Sandbox not found")
		telemetry.ReportError(ctx, "sandbox not found", fmt.Errorf("sandbox %s not found", requestedSandboxID), telemetry.WithSandboxID(requestedSandboxID))
		return
	}

	// Always operate on the canonical sandbox ID from the cache
	sandboxID = sbx.Instance.SandboxID

	if sbx.TeamID == nil || *sbx.TeamID != teamID {
		a.sendAPIStoreError(c, http.StatusForbidden, "Sandbox does not belong to your team")
		telemetry.ReportCriticalError(ctx, "sandbox team mismatch", fmt.Errorf("sandbox %s team mismatch", sandboxID), telemetry.WithSandboxID(sandboxID))
		return
	}

	if teamInfo.Team.ClusterID == nil {
		a.sendAPIStoreError(c, http.StatusConflict, "Team is not associated with a compute cluster")
		telemetry.ReportCriticalError(ctx, "team cluster id missing", fmt.Errorf("team %s has no cluster id", teamID))
		return
	}

	cluster, ok := a.clustersPool.GetClusterById(*teamInfo.Team.ClusterID)
	if !ok {
		a.sendAPIStoreError(c, http.StatusBadGateway, "Cluster control plane is not reachable")
		telemetry.ReportCriticalError(ctx, "cluster not available", fmt.Errorf("cluster %s unavailable", teamInfo.Team.ClusterID.String()))
		return
	}

	edgeBody := edgeapi.SandboxExecRequest{
		Command: body.Command,
	}
	if body.Args != nil {
		edgeBody.Args = body.Args
	}
	if body.Env != nil {
		edgeBody.Env = body.Env
	}
	if body.Cwd != nil {
		edgeBody.Cwd = body.Cwd
	}
	if body.TimeoutSeconds != nil && *body.TimeoutSeconds > 0 {
		timeout := *body.TimeoutSeconds
		edgeBody.TimeoutSeconds = &timeout
	}
	if sbx.ExecutionID != "" {
		execID := sbx.ExecutionID
		edgeBody.ExecutionId = &execID
	}

	edgeResp, err := cluster.GetHttpClient().V1SandboxExecWithResponse(ctx, sandboxID, edgeapi.V1SandboxExecJSONRequestBody(edgeBody))
	if err != nil {
		a.sendAPIStoreError(c, http.StatusBadGateway, "Failed to reach sandbox edge service")
		telemetry.ReportCriticalError(ctx, "sandbox exec edge call failed", err, telemetry.WithSandboxID(sandboxID))
		return
	}

	switch edgeResp.StatusCode() {
	case http.StatusOK:
		if edgeResp.JSON200 == nil {
			a.sendAPIStoreError(c, http.StatusInternalServerError, "Malformed response from sandbox edge")
			telemetry.ReportCriticalError(ctx, "sandbox exec missing payload", fmt.Errorf("edge response missing body for %s", sandboxID), telemetry.WithSandboxID(sandboxID))
			return
		}

		data := edgeResp.JSON200
		stdout := ""
		if data.Stdout != nil {
			stdout = *data.Stdout
		}
		stderr := ""
		if data.Stderr != nil {
			stderr = *data.Stderr
		}
		exitCode := int32(0)
		if data.ExitCode != nil {
			exitCode = *data.ExitCode
		}
		statusText := ""
		if data.Status != nil {
			statusText = *data.Status
		}

		telemetry.ReportEvent(ctx, "sandbox exec completed", telemetry.WithSandboxID(sandboxID))

		c.JSON(http.StatusOK, api.SandboxExecResponse{
			Stdout:   &stdout,
			Stderr:   &stderr,
			ExitCode: &exitCode,
			Status:   &statusText,
		})

		zap.L().Info("sandbox exec completed", logger.WithSandboxID(sandboxID))
		return

	case http.StatusNotFound:
		msg := "Sandbox not found"
		if edgeResp.JSON404 != nil {
			msg = edgeResp.JSON404.Message
		}
		telemetry.ReportError(ctx, "sandbox exec sandbox not found", fmt.Errorf(msg), telemetry.WithSandboxID(sandboxID))
		a.sendAPIStoreError(c, http.StatusNotFound, msg)
		return

	case http.StatusBadRequest:
		msg := edgeResp.Status()
		if edgeResp.JSON400 != nil {
			msg = edgeResp.JSON400.Message
		}
		telemetry.ReportError(ctx, "sandbox exec bad request", fmt.Errorf(msg), telemetry.WithSandboxID(sandboxID))
		a.sendAPIStoreError(c, http.StatusBadRequest, msg)
		return

	case http.StatusUnauthorized:
		msg := edgeResp.Status()
		if edgeResp.JSON401 != nil {
			msg = edgeResp.JSON401.Message
		}
		telemetry.ReportError(ctx, "sandbox exec unauthorized", fmt.Errorf(msg), telemetry.WithSandboxID(sandboxID))
		a.sendAPIStoreError(c, http.StatusUnauthorized, msg)
		return

	default:
		msg := edgeResp.Status()
		telemetry.ReportCriticalError(ctx, "sandbox exec upstream failure", fmt.Errorf(msg), telemetry.WithSandboxID(sandboxID))
		a.sendAPIStoreError(c, http.StatusInternalServerError, msg)
		return
	}
}

func findSandboxByID(sandboxes []*instance.InstanceInfo, primaryID, shortID string) *instance.InstanceInfo {
	normalizedPrimary := utils.ShortID(primaryID)

	for _, candidate := range sandboxes {
		if candidate == nil || candidate.Instance == nil {
			continue
		}

		id := candidate.Instance.SandboxID
		candidateShort := utils.ShortID(id)

		switch {
		case id == primaryID:
			return candidate
		case candidateShort == primaryID:
			return candidate
		case id == shortID:
			return candidate
		case candidateShort == shortID:
			return candidate
		case candidateShort == normalizedPrimary:
			return candidate
		}
	}

	return nil
}
