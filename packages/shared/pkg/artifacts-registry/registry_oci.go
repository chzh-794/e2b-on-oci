package artifacts_registry

import (
	"context"
	"errors"
	"fmt"
	"os"

	"github.com/google/go-containerregistry/pkg/authn"
	"github.com/google/go-containerregistry/pkg/name"
	containerregistry "github.com/google/go-containerregistry/pkg/v1"
	"github.com/google/go-containerregistry/pkg/v1/remote"
	"github.com/google/go-containerregistry/pkg/v1/remote/transport"
)

const ocirRepoBaseEnv = "OCIR_TEMPLATE_REPOSITORY_PATH"

// Optional auth envs
const (
	ocirUsernameEnv = "OCIR_USERNAME"
	ocirPasswordEnv = "OCIR_PASSWORD" // auth token
)

type OCIArtifactsRegistry struct {
	repoBase string
	auth     authn.Authenticator
}

func NewOCIArtifactsRegistryFromEnv() (*OCIArtifactsRegistry, error) {
	base := os.Getenv(ocirRepoBaseEnv)
	if base == "" {
		return nil, fmt.Errorf(
			"%s env var must be set to full OCIR repo path (e.g. us-ashburn-1.ocir.io/namespace/e2b-templates)",
			ocirRepoBaseEnv,
		)
	}

	user := os.Getenv(ocirUsernameEnv)
	pass := os.Getenv(ocirPasswordEnv)

	// Default: anonymous (for public repos)
	var auth authn.Authenticator = authn.Anonymous

	// If creds present, use basic auth (username + auth token)
	if user != "" && pass != "" {
		auth = &authn.Basic{
			Username: user,
			Password: pass,
		}
	}

	return &OCIArtifactsRegistry{
		repoBase: base,
		auth:     auth,
	}, nil
}

func (o *OCIArtifactsRegistry) Tag(templateId, buildId string) string {
	return fmt.Sprintf("%s:%s-%s", o.repoBase, templateId, buildId)
}

func (o *OCIArtifactsRegistry) GetImage(
	ctx context.Context,
	templateId, buildId string,
	platform containerregistry.Platform,
) (containerregistry.Image, error) {
	tag := o.Tag(templateId, buildId)

	ref, err := name.ParseReference(tag)
	if err != nil {
		return nil, fmt.Errorf("invalid OCIR reference %q: %w", tag, err)
	}

	opts := []remote.Option{
		remote.WithContext(ctx),
		remote.WithAuth(o.auth),
	}

	if platform.OS != "" || platform.Architecture != "" || platform.Variant != "" {
		opts = append(opts, remote.WithPlatform(platform))
	}

	img, err := remote.Image(ref, opts...)
	if err != nil {
		var terr *transport.Error
		if errors.As(err, &terr) && terr.StatusCode == 404 {
			return nil, fmt.Errorf("image %q not found (404)", tag)
		}
		return nil, fmt.Errorf("pulling OCIR image %q failed: %w", tag, err)
	}

	return img, nil
}

func (o *OCIArtifactsRegistry) Delete(_ context.Context, _ string, _ string) error {
	// Intentionally a no-op for now.
	return nil
}

// NewOCIArtifactsRegistry provides the same constructor shape as other
// providers (accepting a context). Currently it initializes from the
// environment via NewOCIArtifactsRegistryFromEnv. Keeping this wrapper
// preserves the API expected by callers in registry.go.
func NewOCIArtifactsRegistry(ctx context.Context) (*OCIArtifactsRegistry, error) {
	return NewOCIArtifactsRegistryFromEnv()
}

// GetTag implements the ArtifactsRegistry interface. The existing
// Tag method returns the tag string; wrap it to match the interface
// which returns (string, error) and accepts a context parameter.
func (o *OCIArtifactsRegistry) GetTag(_ context.Context, templateId string, buildId string) (string, error) {
	return o.Tag(templateId, buildId), nil
}
