package handler

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/Tencent/WeKnora/internal/middleware"
	"github.com/Tencent/WeKnora/internal/types"
	"github.com/Tencent/WeKnora/internal/types/interfaces"
	"github.com/gin-gonic/gin"
)

type previewKnowledgeServiceStub struct {
	interfaces.KnowledgeService
	filename   string
	previewURL string
	previewErr error
	opened     bool
	original   bool
}

type closeNotifyRecorder struct {
	*httptest.ResponseRecorder
}

func (r *closeNotifyRecorder) CloseNotify() <-chan bool {
	ch := make(chan bool, 1)
	return ch
}

func (s *previewKnowledgeServiceStub) GetKnowledgeByIDOnly(context.Context, string) (*types.Knowledge, error) {
	return &types.Knowledge{ID: "k1", TenantID: 42, KnowledgeBaseID: "kb1"}, nil
}

func (s *previewKnowledgeServiceStub) GetKnowledgePreviewURL(_ context.Context, _ string, original bool) (string, bool, error) {
	s.original = original
	return s.previewURL, true, s.previewErr
}

func (s *previewKnowledgeServiceStub) GetKnowledgeFile(context.Context, string) (io.ReadCloser, string, error) {
	s.opened = true
	return io.NopCloser(strings.NewReader(`<html><script>alert(1)</script></html>`)), s.filename, nil
}

func TestPreviewKnowledgeFileForcesActiveContentDownload(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.Use(middleware.ErrorHandler())
	router.Use(func(c *gin.Context) {
		c.Set(types.TenantIDContextKey.String(), uint64(42))
		c.Next()
	})

	h := &KnowledgeHandler{kgService: &previewKnowledgeServiceStub{filename: "payload.html"}}
	router.GET("/knowledge/:id/preview", h.PreviewKnowledgeFile)

	req := httptest.NewRequest(http.MethodGet, "/knowledge/k1/preview", nil)
	w := &closeNotifyRecorder{ResponseRecorder: httptest.NewRecorder()}
	router.ServeHTTP(w, req)

	if got, want := w.Code, http.StatusOK; got != want {
		t.Fatalf("status = %d, want %d; body=%s", got, want, w.Body.String())
	}
	if got := w.Header().Get("Content-Type"); got != "application/octet-stream" {
		t.Fatalf("Content-Type = %q, want application/octet-stream", got)
	}
	if got := w.Header().Get("X-Content-Type-Options"); got != "nosniff" {
		t.Fatalf("X-Content-Type-Options = %q, want nosniff", got)
	}
	if got := w.Header().Get("Content-Disposition"); !strings.HasPrefix(got, "attachment") {
		t.Fatalf("Content-Disposition = %q, want attachment", got)
	}
}

func TestPreviewKnowledgeFileRedirectNeverReadsObject(t *testing.T) {
	for _, tc := range []struct {
		name, query string
		fail        bool
		status      int
	}{
		{"redirect", "", false, http.StatusFound},
		{"json for iframe", "?format=json", false, http.StatusOK},
		{"original redirect", "?original=1", false, http.StatusFound},
		{"sign failure does not proxy", "", true, http.StatusInternalServerError},
	} {
		t.Run(tc.name, func(t *testing.T) {
			gin.SetMode(gin.TestMode)
			stub := &previewKnowledgeServiceStub{previewURL: "https://bucket.cos.ap-beijing.myqcloud.com/doc.pdf?ci-process=doc-preview&dstType=html&sign=example"}
			if tc.fail {
				stub.previewErr = fmt.Errorf("signature unavailable")
			}
			router := gin.New()
			router.Use(middleware.ErrorHandler())
			router.Use(func(c *gin.Context) { c.Set(types.TenantIDContextKey.String(), uint64(42)); c.Next() })
			router.GET("/knowledge/:id/preview", (&KnowledgeHandler{kgService: stub}).PreviewKnowledgeFile)
			w := httptest.NewRecorder()
			router.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/knowledge/k1/preview"+tc.query, nil))
			if w.Code != tc.status {
				t.Fatalf("status %d, want %d: %s", w.Code, tc.status, w.Body.String())
			}
			if stub.opened {
				t.Fatal("preview opened the file instead of redirecting")
			}
			if tc.status == http.StatusFound && w.Header().Get("Location") != stub.previewURL {
				t.Fatal("missing signed redirect")
			}
			if tc.status != http.StatusInternalServerError && w.Header().Get("Cache-Control") != "private, no-store" {
				t.Fatal("signed link must not be cached")
			}
			if tc.query == "?original=1" && !stub.original {
				t.Fatal("original mode not forwarded")
			}
		})
	}
}

func TestPreviewKnowledgeFileRequiresAuthentication(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.Use(middleware.ErrorHandler())
	stub := &previewKnowledgeServiceStub{previewURL: "https://example.cos.ap-beijing.myqcloud.com/private"}
	router.GET("/knowledge/:id/preview", (&KnowledgeHandler{kgService: stub}).PreviewKnowledgeFile)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/knowledge/k1/preview", nil))
	if w.Code != http.StatusUnauthorized || w.Header().Get("Location") != "" || stub.opened {
		t.Fatalf("unauthorized preview: %d", w.Code)
	}
}
