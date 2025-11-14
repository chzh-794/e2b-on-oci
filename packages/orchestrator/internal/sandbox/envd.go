package sandbox

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math/rand"
	"net"
	"net/http"
	"sync"
	"time"

	"go.opentelemetry.io/otel/trace"
	"go.uber.org/zap"

	"github.com/e2b-dev/infra/packages/shared/pkg/consts"
)

const (
	initialRequestTimeout = 300 * time.Millisecond
	maxRequestTimeout     = 3 * time.Second
	initialBackoff        = 300 * time.Millisecond
	maxBackoff            = 3 * time.Second
	jitterFraction        = 0.2
)

var (
	backoffMu   sync.Mutex
	backoffRand = rand.New(rand.NewSource(time.Now().UnixNano()))
)

func calculateAttemptTimeout(parentCtx context.Context, attempt int) time.Duration {
	timeout := initialRequestTimeout
	for i := 0; i < attempt; i++ {
		timeout *= 2
		if timeout >= maxRequestTimeout {
			timeout = maxRequestTimeout
			break
		}
	}

	if deadline, ok := parentCtx.Deadline(); ok {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return 0
		}
		if remaining < timeout {
			timeout = remaining
		}
	}

	return timeout
}

func calculateBackoffDelay(attempt int) time.Duration {
	backoff := initialBackoff
	for i := 0; i < attempt; i++ {
		backoff *= 2
		if backoff >= maxBackoff {
			backoff = maxBackoff
			break
		}
	}

	if backoff <= 0 {
		backoff = initialBackoff
	}

	jitter := time.Duration(float64(backoff) * jitterFraction)
	if jitter <= 0 {
		return backoff
	}

	backoffMu.Lock()
	defer backoffMu.Unlock()

	offset := time.Duration(backoffRand.Int63n(int64(jitter)))
	if backoffRand.Intn(2) == 0 {
		if offset >= backoff {
			return backoff
		}
		return backoff - offset
	}

	return backoff + offset
}

// doRequestWithInfiniteRetries does a request with infinite retries until the context is done.
// The parent context should have a deadline or a timeout.
func doRequestWithInfiniteRetries(parentCtx context.Context, method, address string, requestBody []byte, accessToken *string) (*http.Response, error) {
	start := time.Now()

	for attempt := 0; ; attempt++ {
		perAttemptTimeout := calculateAttemptTimeout(parentCtx, attempt)
		if perAttemptTimeout <= 0 {
			return nil, fmt.Errorf("no time remaining to perform request")
		}

		reqCtx, cancel := context.WithTimeout(parentCtx, perAttemptTimeout)
		request, err := http.NewRequestWithContext(reqCtx, method, address, bytes.NewReader(requestBody))
		if err != nil {
			cancel()
			return nil, err
		}

		// make sure request to already authorized envd will not fail
		// this can happen in sandbox resume and in some edge cases when previous request was success, but we continued
		if accessToken != nil {
			request.Header.Set("X-Access-Token", *accessToken)
		}

		response, err := httpClient.Do(request)
		cancel()

		if err == nil {
			zap.L().Debug("envd init request succeeded",
				zap.String("address", address),
				zap.Int("attempt", attempt),
				zap.Duration("elapsed", time.Since(start)))
			return response, nil
		}

		backoffDelay := calculateBackoffDelay(attempt)
		zap.L().Info("envd init request failed",
			zap.String("address", address),
			zap.Error(err),
			zap.Int("attempt", attempt),
			zap.Duration("attempt_timeout", perAttemptTimeout),
			zap.Duration("next_backoff", backoffDelay))

		select {
		case <-parentCtx.Done():
			return nil, fmt.Errorf("%w with cause: %w", parentCtx.Err(), context.Cause(parentCtx))
		case <-time.After(backoffDelay):
		}
	}
}

type PostInitJSONBody struct {
	EnvVars     *map[string]string `json:"envVars"`
	AccessToken *string            `json:"accessToken,omitempty"`
}

func (s *Sandbox) initEnvd(ctx context.Context, tracer trace.Tracer, envVars map[string]string, accessToken *string) error {
	childCtx, childSpan := tracer.Start(ctx, "envd-init")
	defer childSpan.End()

	sandboxID := "unknown"
	executionID := "unknown"
	if s.Metadata != nil && s.Metadata.Config != nil {
		sandboxID = s.Metadata.Config.SandboxId
		executionID = s.Metadata.Config.ExecutionId
	}

	targetIP := envdTargetIP(s.Slot)
	if targetIP == nil && s.Slot != nil {
		targetIP = s.Slot.HostIP()
	}
	if targetIP == nil {
		targetIP = net.ParseIP("127.0.0.1")
	}

	address := fmt.Sprintf("http://%s:%d/init", targetIP.String(), consts.DefaultEnvdServerPort)
	zap.L().Info("resolved envd init target",
		zap.String("sandbox_id", sandboxID),
		zap.String("execution_id", executionID),
		zap.String("address", address))

	hostPort := fmt.Sprintf("%s:%d", targetIP.String(), consts.DefaultEnvdServerPort)
	probeTimeout := 2 * time.Second
	if conn, probeErr := net.DialTimeout("tcp", hostPort, probeTimeout); probeErr != nil {
		zap.L().Warn("preflight envd tcp probe failed",
			zap.String("sandbox_id", sandboxID),
			zap.String("execution_id", executionID),
			zap.String("host_port", hostPort),
			zap.Duration("timeout", probeTimeout),
			zap.Error(probeErr))
	} else {
		zap.L().Info("preflight envd tcp probe succeeded",
			zap.String("sandbox_id", sandboxID),
			zap.String("execution_id", executionID),
			zap.String("host_port", hostPort))
		_ = conn.Close()
	}

	jsonBody := &PostInitJSONBody{
		EnvVars:     &envVars,
		AccessToken: accessToken,
	}

	body, err := json.Marshal(jsonBody)
	if err != nil {
		return err
	}

	response, err := doRequestWithInfiniteRetries(childCtx, "POST", address, body, accessToken)
	if err != nil {
		return fmt.Errorf("failed to init envd: %w", err)
	}

	defer response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		bodyBytes, _ := io.ReadAll(response.Body)
		zap.L().Warn("unexpected envd status", zap.Int("status", response.StatusCode), zap.String("body", string(bodyBytes)))
		return fmt.Errorf("unexpected status code: %d", response.StatusCode)
	}

	_, err = io.Copy(io.Discard, response.Body)
	if err != nil {
		return err
	}

	return nil
}
