package storage

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/e2b-dev/infra/packages/shared/pkg/env"
	"github.com/e2b-dev/infra/packages/shared/pkg/utils"
	"github.com/oracle/oci-go-sdk/v65/common"
	"github.com/oracle/oci-go-sdk/v65/common/auth"
	"github.com/oracle/oci-go-sdk/v65/objectstorage"
)

const (
	ociOperationTimeout = 5 * time.Second
	ociWriteTimeout     = 120 * time.Second
	ociReadTimeout      = 15 * time.Second
)

// OCIBucketStorageProvider implements Object Storage-backed template storage.
type OCIBucketStorageProvider struct {
	client     *objectstorage.ObjectStorageClient
	namespace  string
	bucketName string
	region     string
}

// OCIBucketStorageObjectProvider handles CRUD for a single object.
type OCIBucketStorageObjectProvider struct {
	client     *objectstorage.ObjectStorageClient
	namespace  string
	bucketName string
	path       string
	ctx        context.Context
}

// NewOCIBucketStorageProvider initializes the Object Storage client using instance principals.
func NewOCIBucketStorageProvider(ctx context.Context, bucketName string) (*OCIBucketStorageProvider, error) {
	region := utils.RequiredEnv("OCI_REGION", "OCI region for Object Storage (e.g., us-ashburn-1)")
	namespace := env.GetEnv("OCI_NAMESPACE", "")

	provider, err := auth.InstancePrincipalConfigurationProvider()
	if err != nil {
		return nil, fmt.Errorf("failed to create OCI Instance Principal provider: %w", err)
	}

	client, err := objectstorage.NewObjectStorageClientWithConfigurationProvider(provider)
	if err != nil {
		return nil, fmt.Errorf("failed to create OCI Object Storage client: %w", err)
	}
	client.SetRegion(region)

	if namespace == "" {
		nsCtx, cancel := context.WithTimeout(ctx, ociOperationTimeout)
		defer cancel()
		nsResp, err := client.GetNamespace(nsCtx, objectstorage.GetNamespaceRequest{})
		if err != nil {
			return nil, fmt.Errorf("failed to get OCI Object Storage namespace: %w", err)
		}
		namespace = *nsResp.Value
	}

	return &OCIBucketStorageProvider{
		client:     &client,
		namespace:  namespace,
		bucketName: bucketName,
		region:     region,
	}, nil
}

func (o *OCIBucketStorageProvider) DeleteObjectsWithPrefix(ctx context.Context, prefix string) error {
	start := ""

	for {
		listCtx, listCancel := context.WithTimeout(ctx, ociOperationTimeout)
		req := objectstorage.ListObjectsRequest{
			NamespaceName: &o.namespace,
			BucketName:    &o.bucketName,
			Prefix:        &prefix,
		}
		if start != "" {
			req.Start = &start
		}

		resp, err := o.client.ListObjects(listCtx, req)
		listCancel()
		if err != nil {
			return err
		}

		for _, obj := range resp.Objects {
			delCtx, delCancel := context.WithTimeout(ctx, ociOperationTimeout)
			_, delErr := o.client.DeleteObject(delCtx, objectstorage.DeleteObjectRequest{
				NamespaceName: &o.namespace,
				BucketName:    &o.bucketName,
				ObjectName:    obj.Name,
			})
			delCancel()
			if delErr != nil && !isOCIObjectNotFound(delErr) {
				return delErr
			}
		}

		if resp.NextStartWith == nil || *resp.NextStartWith == "" {
			break
		}
		start = *resp.NextStartWith
	}

	return nil
}

func (o *OCIBucketStorageProvider) GetDetails() string {
	return fmt.Sprintf("[OCI Object Storage, bucket %s, namespace %s, region %s]", o.bucketName, o.namespace, o.region)
}

func (o *OCIBucketStorageProvider) OpenObject(ctx context.Context, path string) (StorageObjectProvider, error) {
	return &OCIBucketStorageObjectProvider{
		client:     o.client,
		namespace:  o.namespace,
		bucketName: o.bucketName,
		path:       path,
		ctx:        ctx,
	}, nil
}

func (o *OCIBucketStorageObjectProvider) WriteTo(dst io.Writer) (int64, error) {
	ctx, cancel := context.WithTimeout(o.ctx, ociReadTimeout)
	defer cancel()

	resp, err := o.client.GetObject(ctx, objectstorage.GetObjectRequest{
		NamespaceName: &o.namespace,
		BucketName:    &o.bucketName,
		ObjectName:    &o.path,
	})
	if err != nil {
		if isOCIObjectNotFound(err) {
			return 0, ErrorObjectNotExist
		}
		return 0, err
	}
	defer resp.Content.Close()

	return io.Copy(dst, resp.Content)
}

func (o *OCIBucketStorageObjectProvider) WriteFromFileSystem(path string) error {
	ctx, cancel := context.WithTimeout(o.ctx, ociWriteTimeout)
	defer cancel()

	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()

	_, err = o.client.PutObject(ctx, objectstorage.PutObjectRequest{
		NamespaceName: &o.namespace,
		BucketName:    &o.bucketName,
		ObjectName:    &o.path,
		PutObjectBody: file,
	})

	return err
}

func (o *OCIBucketStorageObjectProvider) ReadFrom(src io.Reader) (int64, error) {
	ctx, cancel := context.WithTimeout(o.ctx, ociWriteTimeout)
	defer cancel()

	_, err := o.client.PutObject(ctx, objectstorage.PutObjectRequest{
		NamespaceName: &o.namespace,
		BucketName:    &o.bucketName,
		ObjectName:    &o.path,
		PutObjectBody: io.NopCloser(src),
	})

	return 0, err
}

func (o *OCIBucketStorageObjectProvider) ReadAt(buff []byte, off int64) (n int, err error) {
	ctx, cancel := context.WithTimeout(o.ctx, ociReadTimeout)
	defer cancel()

	rangeHeader := fmt.Sprintf("bytes=%d-%d", off, off+int64(len(buff))-1)
	resp, err := o.client.GetObject(ctx, objectstorage.GetObjectRequest{
		NamespaceName: &o.namespace,
		BucketName:    &o.bucketName,
		ObjectName:    &o.path,
		Range:         &rangeHeader,
	})
	if err != nil {
		if isOCIObjectNotFound(err) {
			return 0, ErrorObjectNotExist
		}
		return 0, err
	}
	defer resp.Content.Close()

	n, err = io.ReadFull(resp.Content, buff)
	if errors.Is(err, io.ErrUnexpectedEOF) {
		err = io.EOF
	}
	return n, err
}

func (o *OCIBucketStorageObjectProvider) Size() (int64, error) {
	ctx, cancel := context.WithTimeout(o.ctx, ociOperationTimeout)
	defer cancel()

	resp, err := o.client.HeadObject(ctx, objectstorage.HeadObjectRequest{
		NamespaceName: &o.namespace,
		BucketName:    &o.bucketName,
		ObjectName:    &o.path,
	})
	if err != nil {
		if isOCIObjectNotFound(err) {
			return 0, ErrorObjectNotExist
		}
		return 0, err
	}

	if resp.ContentLength == nil {
		return 0, errors.New("content length missing in OCI response")
	}

	return *resp.ContentLength, nil
}

func (o *OCIBucketStorageObjectProvider) Delete() error {
	ctx, cancel := context.WithTimeout(o.ctx, ociOperationTimeout)
	defer cancel()

	_, err := o.client.DeleteObject(ctx, objectstorage.DeleteObjectRequest{
		NamespaceName: &o.namespace,
		BucketName:    &o.bucketName,
		ObjectName:    &o.path,
	})
	if isOCIObjectNotFound(err) {
		return ErrorObjectNotExist
	}
	return err
}

func isOCIObjectNotFound(err error) bool {
	var serviceErr common.ServiceError
	if errors.As(err, &serviceErr) {
		return serviceErr.GetHTTPStatusCode() == 404
	}
	return false
}
