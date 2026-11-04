package file

import (
	"context"
	"github.com/Tencent/WeKnora/internal/types"
	"github.com/Tencent/WeKnora/internal/types/interfaces"
	"net/url"
	"strings"
	"testing"
)

func TestCOSPreviewURL(t *testing.T) {
	svc, err := newCosClient("test-1250000000", "ap-beijing", "test-id", "test-key")
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		filename       string
		original, html bool
	}{
		{"report.XLS", false, true}, {"report.pdf", false, true},
		{"report.pdf", true, false}, {"image.png", false, false}, {"payload.html", false, false},
	} {
		t.Run(tc.filename+map[bool]string{true: "-original"}[tc.original], func(t *testing.T) {
			raw, html, err := svc.GetPreviewURL(context.Background(), "cos://test-1250000000/ap-beijing/docs/42/report.pdf", tc.filename, tc.original)
			if err != nil {
				t.Fatal(err)
			}
			u, err := url.Parse(raw)
			if err != nil {
				t.Fatal(err)
			}
			if html != tc.html || u.Host != "test-1250000000.cos.ap-beijing.myqcloud.com" {
				t.Fatalf("unexpected preview %s / %v", raw, html)
			}
			q := u.Query()
			signature := q
			if html {
				if q.Get("ci-process") != "doc-preview" || q.Get("dstType") != "html" {
					t.Fatal("missing CI processing parameters")
				}
				if strings.Contains(strings.ToLower(q.Get("sign")), "%3b") || !strings.Contains(q.Get("sign"), ";") {
					t.Fatal("CI authorization was URL encoded twice")
				}
				signature, err = url.ParseQuery(strings.ReplaceAll(q.Get("sign"), ";", "%3B"))
				if err != nil {
					t.Fatal(err)
				}
			}
			if signature.Get("q-signature") == "" || !strings.Contains(signature.Get("q-ak"), "test-id") {
				t.Fatal("missing object authorization")
			}
		})
	}
	if _, _, err := svc.GetPreviewURL(context.Background(), "cos://other/ap-beijing/docs/report.pdf", "report.pdf", false); err == nil {
		t.Fatal("accepted foreign bucket")
	}
}

func TestCOSPreviewURLThroughStorageWrappers(t *testing.T) {
	cos, err := newCosClient("test-1250000000", "ap-beijing", "test-id", "test-key")
	if err != nil {
		t.Fatal(err)
	}
	scoped := NewBackendScopedFileService("cos-instance", cos)
	physical := types.BuildStorageBackendPath("cos-instance", "cos://test-1250000000/ap-beijing/docs/42/report.pdf")
	catalog := &catalogStub{ref: "resource://AbCdEfGhIjKlMnOpQrStUv", resource: &types.StoredResource{PhysicalPath: physical}}
	wrapped := NewResourceCatalogFileService(scoped, catalog)
	raw, html, err := wrapped.(interfaces.FilePreviewService).GetPreviewURL(context.Background(), catalog.ref, "report.pdf", false)
	if err != nil || !html || !strings.Contains(raw, "ci-process=doc-preview") {
		t.Fatalf("wrapped preview failed: %s %v %v", raw, html, err)
	}
	_, _, err = scoped.(interfaces.FilePreviewService).GetPreviewURL(context.Background(), types.BuildStorageBackendPath("wrong-instance", "cos://test-1250000000/ap-beijing/docs/42/report.pdf"), "report.pdf", false)
	if err == nil {
		t.Fatal("accepted another storage instance")
	}
}
