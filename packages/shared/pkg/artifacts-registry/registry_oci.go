package artifacts_registry

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/google/go-containerregistry/pkg/authn"
	"github.com/google/go-containerregistry/pkg/name"
	containerregistry "github.com/google/go-containerregistry/pkg/v1"
	"github.com/google/go-containerregistry/pkg/v1/remote"
	"github.com/google/go-containerregistry/pkg/v1/remote/transport"
	"github.com/oracle/oci-go-sdk/v65/artifacts"
	"github.com/oracle/oci-go-sdk/v65/common"
	"github.com/oracle/oci-go-sdk/v65/common/auth"

	"github.com/e2b-dev/infra/packages/shared/pkg/env"
	"github.com/e2b-dev/infra/packages/shared/pkg/utils"
)

const (
	ociAuthTimeout = 10 * time.Second
)

// OCIArtifactsRegistry implements OCIR-backed registry operations.
type OCIArtifactsRegistry struct {
	repositoryName string
	namespace      string
	region         string
	endpoint       string
	client         *artifacts.ArtifactsClient
}

func NewOCIArtifactsRegistry(ctx context.Context) (*OCIArtifactsRegistry, error) {
	region := utils.RequiredEnv("OCI_REGION", "OCI region for OCIR (e.g., us-ashburn-1)")
	namespace := utils.RequiredEnv("OCI_NAMESPACE", "OCI Object Storage namespace (also used for OCIR)")
	repoName := utils.RequiredEnv("OCI_CONTAINER_REPOSITORY_NAME", "OCIR container repository display name")

	configProvider, err := auth.InstancePrincipalConfigurationProvider()
	if err != nil {
		return nil, fmt.Errorf("failed to create OCI Instance Principal provider: %w", err)
	}

	client, err := artifacts.NewArtifactsClientWithConfigurationProvider(configProvider)
	if err != nil {
		return nil, fmt.Errorf("failed to init OCI Artifacts client: %w", err)
	}
	client.SetRegion(region)

	return &OCIArtifactsRegistry{
		repositoryName: repoName,
		namespace:      namespace,
		region:         region,
		endpoint:       fmt.Sprintf("%s.ocir.io", region),
		client:         &client,
	}, nil
}

func (o *OCIArtifactsRegistry) Delete(ctx context.Context, templateId string, buildId string) error {
	ref, err := o.imageRef(templateId, buildId)
	if err != nil {
		return err
	}

	auth, err := o.getAuth(ctx)
	if err != nil {
		return fmt.Errorf("failed to get OCIR auth: %w", err)
	}

	// Resolve digest first, then delete by digest for registry parity.
	desc, err := remote.Get(ref, remote.WithContext(ctx), remote.WithAuth(auth))
	if err != nil {
		if isOCIRNotFound(err) {
			return ErrImageNotExists
		}
		return fmt.Errorf("failed to resolve OCIR image: %w", err)
	}

	digestRef := ref.Context().Digest(desc.Descriptor.Digest.String())
	if err := remote.Delete(digestRef, remote.WithContext(ctx), remote.WithAuth(auth)); err != nil {
		if isOCIRNotFound(err) {
			return ErrImageNotExists
		}
		return fmt.Errorf("failed to delete image from OCIR: %w", err)
	}

	return nil
}

func (o *OCIArtifactsRegistry) GetTag(ctx context.Context, templateId string, buildId string) (string, error) {
	ref, err := o.imageRef(templateId, buildId)
	if err != nil {
		return "", err
	}
	return ref.Name(), nil
}

func (o *OCIArtifactsRegistry) GetImage(ctx context.Context, templateId string, buildId string, platform containerregistry.Platform) (containerregistry.Image, error) {
	ref, err := o.imageRef(templateId, buildId)
	if err != nil {
		return nil, err
	}

	auth, err := o.getAuth(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to get OCIR auth: %w", err)
	}

	img, err := remote.Image(ref, remote.WithContext(ctx), remote.WithAuth(auth), remote.WithPlatform(platform))
	if err != nil {
		if isOCIRNotFound(err) {
			return nil, ErrImageNotExists
		}
		return nil, fmt.Errorf("failed to pull image from OCIR: %w", err)
	}

	return img, nil
}

func (o *OCIArtifactsRegistry) EnsureImage(ctx context.Context, templateId string, buildId string, platform containerregistry.Platform) (containerregistry.Image, error) {
	img, err := o.GetImage(ctx, templateId, buildId, platform)
	if err == nil {
		return img, nil
	}

	if !errors.Is(err, ErrImageNotExists) {
		return nil, err
	}

	// Bootstrap a fallback base image, tag, and push it to OCIR, then pull it.
	baseImageRef := env.GetEnv("OCIR_FALLBACK_BASE_IMAGE", "ubuntu:22.04")
	baseRef, parseErr := name.ParseReference(baseImageRef)
	if parseErr != nil {
		return nil, fmt.Errorf("invalid fallback base image %q: %w", baseImageRef, parseErr)
	}

	fallbackImg, pullErr := remote.Image(baseRef, remote.WithContext(ctx), remote.WithPlatform(platform))
	if pullErr != nil {
		return nil, fmt.Errorf("failed to pull fallback base image %s: %w", baseImageRef, pullErr)
	}

	targetRef, refErr := o.imageRef(templateId, buildId)
	if refErr != nil {
		return nil, refErr
	}

	auth, authErr := o.getAuth(ctx)
	if authErr != nil {
		return nil, fmt.Errorf("failed to get OCIR auth for fallback push: %w", authErr)
	}

	if writeErr := remote.Write(targetRef, fallbackImg, remote.WithContext(ctx), remote.WithAuth(auth)); writeErr != nil {
		return nil, fmt.Errorf("failed to push fallback image to OCIR: %w", writeErr)
	}

	// Pull again via GetImage to ensure we return a validated image handle.
	return o.GetImage(ctx, templateId, buildId, platform)
}

func (o *OCIArtifactsRegistry) getAuth(ctx context.Context) (*authn.Basic, error) {
	if basic, err := o.fetchInstancePrincipalToken(ctx); err == nil {
		return basic, nil
	} else {
		// Keep the failure reason so we can diagnose why IP token minting failed.
		ipErr := err

		// Fallback: explicit creds if provided
		if user := env.GetEnv("OCIR_USERNAME", ""); user != "" {
			pass := utils.RequiredEnv("OCIR_PASSWORD", "OCIR password/auth token")
			return &authn.Basic{Username: user, Password: pass}, nil
		}

		return nil, fmt.Errorf("failed to acquire OCIR auth token via instance principal: %w (and no OCIR_USERNAME/OCIR_PASSWORD provided)", ipErr)
	}
}

func (o *OCIArtifactsRegistry) imageRef(templateId string, buildId string) (name.Reference, error) {
	// <region>.ocir.io/<namespace>/<repo>/<templateId>:<buildId>
	ref := fmt.Sprintf("%s/%s/%s/%s:%s", o.endpoint, o.namespace, o.repositoryName, templateId, buildId)
	return name.ParseReference(ref)
}

type ocirTokenResponse struct {
	Token    *string `json:"token"`
	Username *string `json:"username"`
}

// fetchInstancePrincipalToken signs the OCIR token request with the instance principal signer.
func (o *OCIArtifactsRegistry) fetchInstancePrincipalToken(ctx context.Context) (*authn.Basic, error) {
	provider, err := auth.InstancePrincipalConfigurationProvider()
	if err != nil {
		return nil, fmt.Errorf("cannot create instance principal provider: %w", err)
	}

	signer := common.DefaultRequestSigner(provider)
	url := fmt.Sprintf("https://%s/20160918/auth/token", o.endpoint)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}

	if err := signer.Sign(req); err != nil {
		return nil, fmt.Errorf("failed to sign OCIR token request: %w", err)
	}

	client := http.Client{Timeout: ociAuthTimeout}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to request OCIR token: %w", err)
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("unexpected status from OCIR token endpoint: %s body=%s", resp.Status, strings.TrimSpace(string(body)))
	}

	var tokenResp ocirTokenResponse
	if err := json.Unmarshal(body, &tokenResp); err != nil {
		return nil, fmt.Errorf("failed to decode OCIR token response: %w", err)
	}

	if tokenResp.Token == nil || *tokenResp.Token == "" {
		return nil, errors.New("empty token in OCIR token response")
	}

	username := fmt.Sprintf("%s/oci", o.namespace)
	if tokenResp.Username != nil && *tokenResp.Username != "" {
		username = *tokenResp.Username
	}

	return &authn.Basic{
		Username: username,
		Password: *tokenResp.Token,
	}, nil
}

func isOCIRNotFound(err error) bool {
	var te *transport.Error
	if errors.As(err, &te) && te.StatusCode == http.StatusNotFound {
		return true
	}

	var se common.ServiceError
	return errors.As(err, &se) && se.GetHTTPStatusCode() == http.StatusNotFound
}
