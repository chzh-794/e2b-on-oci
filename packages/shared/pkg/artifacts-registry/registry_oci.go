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

	"github.com/e2b-dev/infra/packages/shared/pkg/consts"
)

type OCIArtifactsRegistry struct {
	// Example: us-ashburn-1.ocir.io/ideshil2wbzt/e2b-templates
	repoBase string
	// Auth for OCIR (username/password or anonymous)
	auth authn.Authenticator
}

func NewOCIArtifactsRegistry(ctx context.Context) (*OCIArtifactsRegistry, error) {
	// Prefer explicit full path if set (e.g. us-ashburn-1.ocir.io/namespace/repo)
	base := consts.OCIRTemplateRepositoryPath
	if base == "" {
		if consts.OCIRegion == "" || consts.OCIRNamespace == "" || consts.OCIRTemplateRepository == "" {
			return nil, fmt.Errorf("missing OCIR config: set OCI_REGION, OCIR_NAMESPACE, OCIR_TEMPLATE_REPOSITORY or OCIR_TEMPLATE_REPOSITORY_PATH")
		}
		base = fmt.Sprintf("%s.ocir.io/%s/%s",
			consts.OCIRegion,
			consts.OCIRNamespace,
			consts.OCIRTemplateRepository,
		)
	}

	user := os.Getenv("OCIR_USERNAME")
	pass := os.Getenv("OCIR_PASSWORD")

	var auth authn.Authenticator = authn.Anonymous
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

func (o *OCIArtifactsRegistry) tagFor(templateId, buildId string) string {
	// Match other providers: <repo>:<templateId>-<buildId>
	return fmt.Sprintf("%s:%s-%s", o.repoBase, templateId, buildId)
}

func (o *OCIArtifactsRegistry) GetTag(ctx context.Context, templateId, buildId string) (string, error) {
	return o.tagFor(templateId, buildId), nil
}

func (o *OCIArtifactsRegistry) GetImage(
	ctx context.Context,
	templateId, buildId string,
	platform containerregistry.Platform,
) (containerregistry.Image, error) {
	tag := o.tagFor(templateId, buildId)

	ref, err := name.ParseReference(tag)
	if err != nil {
		return nil, fmt.Errorf("invalid OCIR reference %q: %w", tag, err)
	}

	opts := []remote.Option{
		remote.WithContext(ctx),
		remote.WithAuth(o.auth),
	}

	// If caller passes a non-zero platform, honor it.
	// Zero value (all fields empty) is effectively "no platform preference".
	if platform.OS != "" || platform.Architecture != "" || platform.Variant != "" {
		opts = append(opts, remote.WithPlatform(platform))
	}

	img, err := remote.Image(ref, opts...)
	if err != nil {
		var terr *transport.Error
		if errors.As(err, &terr) && terr.StatusCode == 404 {
			return nil, ErrImageNotExists
		}
		return nil, fmt.Errorf("pulling OCIR image %q failed: %w", tag, err)
	}

	return img, nil
}

func (o *OCIArtifactsRegistry) Delete(ctx context.Context, templateId string, buildId string) error {
	tag := o.tagFor(templateId, buildId)

	ref, err := name.ParseReference(tag)
	if err != nil {
		return fmt.Errorf("invalid OCIR reference %q: %w", tag, err)
	}

	err = remote.Delete(
		ref,
		remote.WithContext(ctx),
		remote.WithAuth(o.auth),
	)
	if err != nil {
		var terr *transport.Error
		if errors.As(err, &terr) && terr.StatusCode == 404 {
			// Mirror behavior of other providers: 404 => image does not exist
			return ErrImageNotExists
		}
		return fmt.Errorf("deleting OCIR image %q failed: %w", tag, err)
	}

	return nil
}
