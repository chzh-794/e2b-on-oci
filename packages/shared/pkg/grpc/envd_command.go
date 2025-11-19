package grpc

import (
	"context"
	"encoding/base64"
	"fmt"
	"net/http"
	"net/url"
	"os"

	"connectrpc.com/connect"

	"github.com/e2b-dev/infra/packages/shared/pkg/consts"
)

func StreamToChannel[Res any](ctx context.Context, stream *connect.ServerStreamForClient[Res]) (<-chan *Res, <-chan error) {
	out := make(chan *Res)
	errCh := make(chan error, 1)

	go func() {
		defer close(out)
		defer close(errCh)

		receiveCount := 0
		fmt.Fprintf(os.Stderr, "[StreamToChannel] Starting receive loop\n")
		
		for stream.Receive() {
			receiveCount++
			if receiveCount%10 == 0 {
				fmt.Fprintf(os.Stderr, "[StreamToChannel] Received %d messages\n", receiveCount)
			}
			
			select {
			case <-ctx.Done():
				// Context canceled, exit the goroutine
				fmt.Fprintf(os.Stderr, "[StreamToChannel] Context cancelled, exiting\n")
				return
			case out <- stream.Msg():
				// Send the message to the channel
				if receiveCount <= 5 {
					fmt.Fprintf(os.Stderr, "[StreamToChannel] Sent message %d to channel\n", receiveCount)
				}
			}
		}

		fmt.Fprintf(os.Stderr, "[StreamToChannel] stream.Receive() returned false, loop exited. Total messages: %d\n", receiveCount)

		if err := stream.Err(); err != nil {
			fmt.Fprintf(os.Stderr, "[StreamToChannel] Stream error: %v\n", err)
			errCh <- err
			return
		}
		
		fmt.Fprintf(os.Stderr, "[StreamToChannel] Stream closed normally, no error\n")
	}()

	return out, errCh
}

func SetSandboxHeader(header http.Header, hostname string, sandboxID string) error {
	domain, err := extractDomain(hostname)
	if err != nil {
		return fmt.Errorf("failed to extract domain from hostname: %w", err)
	}
	// Construct the host (<port>-<sandbox id>-<old client id>.e2b.app)
	host := fmt.Sprintf("%d-%s-00000000.%s", consts.DefaultEnvdServerPort, sandboxID, domain)

	header.Set("Host", host)

	return nil
}

func SetUserHeader(header http.Header, user string) {
	userString := fmt.Sprintf("%s:", user)
	userBase64 := base64.StdEncoding.EncodeToString([]byte(userString))
	basic := fmt.Sprintf("Basic %s", userBase64)
	header.Set("Authorization", basic)
}

func extractDomain(input string) (string, error) {
	parsedURL, err := url.Parse(input)
	if err != nil || parsedURL.Host == "" {
		return "", fmt.Errorf("invalid URL: %s", input)
	}

	return parsedURL.Hostname(), nil
}
