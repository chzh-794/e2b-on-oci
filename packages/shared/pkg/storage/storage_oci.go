package storage

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"time"
	"strings"

	"github.com/oracle/oci-go-sdk/v65/common"
	"github.com/oracle/oci-go-sdk/v65/objectstorage"
)

const (
	ociOperationTimeout = 5 * time.Second
	ociWriteTimeout     = 120 * time.Second
	ociReadTimeout      = 15 * time.Second
)

type OCIBucketStorageProvider struct {
	client     *objectstorage.ObjectStorageClient
	namespace  string
	bucketName string
	region     string
}

type OCIBucketStorageObjectProvider struct {
	client     *objectstorage.ObjectStorageClient
	namespace  string
	bucketName string
	path       string
	ctx        context.Context
}

func NewOCIBucketStorageProvider(ctx context.Context, bucketName string, region string) (*OCIBucketStorageProvider, error) {
	provider := common.DefaultConfigProvider()
	client, err := objectstorage.NewObjectStorageClientWithConfigurationProvider(provider)
	if err != nil {
		return nil, fmt.Errorf("failed to create OCI Object Storage client: %w", err)
	}
	client.SetRegion(region)
	nsCtx, cancel := context.WithTimeout(ctx, ociOperationTimeout)
	defer cancel()
	nsResp, err := client.GetNamespace(nsCtx, objectstorage.GetNamespaceRequest{})
	if err != nil {
		return nil, fmt.Errorf("failed to get OCI Object Storage namespace: %w", err)
	}
	return &OCIBucketStorageProvider{
		client:     &client,
		namespace:  *nsResp.Value,
		bucketName: bucketName,
		region:     region,
	}, nil
}

func (o *OCIBucketStorageProvider) DeleteObjectsWithPrefix(ctx context.Context, prefix string) error {
	ctx, cancel := context.WithTimeout(ctx, ociOperationTimeout)
	defer cancel()
	var start string
	var toDelete []string

	for {
		listReq := objectstorage.ListObjectsRequest{
			NamespaceName: &o.namespace,
			BucketName:    &o.bucketName,
			Prefix:        &prefix,
			Start:         &start,
		}
		resp, err := o.client.ListObjects(ctx, listReq)
		if err != nil {
			return err
		}
		for _, obj := range resp.ListObjects.Objects {
			toDelete = append(toDelete, *obj.Name)
		}
		nextStart := resp.RawResponse.Header.Get("opc-next-start")
		if nextStart == "" {
			break
		}
		start = nextStart
	}
	// OCI does not support real batch-delete; so delete individually
	for _, name := range toDelete {
		delReq := objectstorage.DeleteObjectRequest{
			NamespaceName: &o.namespace,
			BucketName:    &o.bucketName,
			ObjectName:    &name,
		}
		_, err := o.client.DeleteObject(ctx, delReq)
		if err != nil {
			return fmt.Errorf("failed to delete object %s: %w", name, err)
		}
	}
	return nil
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

func (o *OCIBucketStorageProvider) GetDetails() string {
	return fmt.Sprintf("[OCI Storage, bucket: %s, region: %s, namespace: %s]", o.bucketName, o.region, o.namespace)
}

func (o *OCIBucketStorageObjectProvider) WriteTo(dst io.Writer) (int64, error) {
	ctx, cancel := context.WithTimeout(o.ctx, ociReadTimeout)
	defer cancel()
	getReq := objectstorage.GetObjectRequest{
		NamespaceName: &o.namespace,
		BucketName:    &o.bucketName,
		ObjectName:    &o.path,
	}
	resp, err := o.client.GetObject(ctx, getReq)
	if err != nil {
		if isOCIObjectNotExist(err) {
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
	putReq := objectstorage.PutObjectRequest{
		NamespaceName: &o.namespace,
		BucketName:    &o.bucketName,
		ObjectName:    &o.path,
		PutObjectBody: file,
	}
	_, err = o.client.PutObject(ctx, putReq)
	return err
}

func (o *OCIBucketStorageObjectProvider) ReadFrom(src io.Reader) (int64, error) {
	ctx, cancel := context.WithTimeout(o.ctx, ociWriteTimeout)
	defer cancel()
	putReq := objectstorage.PutObjectRequest{
		NamespaceName: &o.namespace,
		BucketName:    &o.bucketName,
		ObjectName:    &o.path,
		PutObjectBody: io.NopCloser(src),
	}
	_, err := o.client.PutObject(ctx, putReq)
	if err != nil {
		return 0, err
	}
	return 0, nil
}

func (o *OCIBucketStorageObjectProvider) ReadAt(buff []byte, off int64) (int, error) {
	ctx, cancel := context.WithTimeout(o.ctx, ociReadTimeout)
	defer cancel()
	rangeHeader := fmt.Sprintf("bytes=%d-%d", off, off+int64(len(buff))-1)
	getReq := objectstorage.GetObjectRequest{
		NamespaceName: &o.namespace,
		BucketName:    &o.bucketName,
		ObjectName:    &o.path,
		Range:         &rangeHeader,
	}
	resp, err := o.client.GetObject(ctx, getReq)
	if err != nil {
		if isOCIObjectNotExist(err) {
			return 0, ErrorObjectNotExist
		}
		return 0, err
	}
	defer resp.Content.Close()
	n, err := io.ReadFull(resp.Content, buff)
	if errors.Is(err, io.ErrUnexpectedEOF) {
		err = io.EOF
	}
	return n, err
}

func (o *OCIBucketStorageObjectProvider) Size() (int64, error) {
	ctx, cancel := context.WithTimeout(o.ctx, ociOperationTimeout)
	defer cancel()
	headReq := objectstorage.HeadObjectRequest{
		NamespaceName: &o.namespace,
		BucketName:    &o.bucketName,
		ObjectName:    &o.path,
	}
	resp, err := o.client.HeadObject(ctx, headReq)
	if err != nil {
		return 0, err
	}
	return *resp.ContentLength, nil
}

func (o *OCIBucketStorageObjectProvider) Delete() error {
	ctx, cancel := context.WithTimeout(o.ctx, ociOperationTimeout)
	defer cancel()
	delReq := objectstorage.DeleteObjectRequest{
		NamespaceName: &o.namespace,
		BucketName:    &o.bucketName,
		ObjectName:    &o.path,
	}
	_, err := o.client.DeleteObject(ctx, delReq)
	return err
}

func isOCIObjectNotExist(err error) bool {
	// Check for "ObjectNotFound" using error string, since OCI SDK does not provide a typed error for this condition.
	return err != nil && (strings.Contains(err.Error(), "ObjectNotFound") || strings.Contains(err.Error(), "404"))
}
