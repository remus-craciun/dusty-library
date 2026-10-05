package api

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/remus/dusty-library/server/internal/store"
)

type testEnv struct {
	t     *testing.T
	srv   *httptest.Server
	token string
}

func newEnv(t *testing.T) *testEnv {
	t.Helper()
	dir := t.TempDir()
	st, err := store.Open(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	h := New(Options{
		Store:    st,
		BooksDir: filepath.Join(dir, "books"),
		Logger:   slog.New(slog.NewTextHandler(io.Discard, nil)),
		Web: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Write([]byte("web"))
		}),
	})
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)
	return &testEnv{t: t, srv: srv}
}

func (e *testEnv) do(method, path string, body any, into any) *http.Response {
	e.t.Helper()
	var rdr io.Reader
	ct := ""
	switch b := body.(type) {
	case nil:
	case *bytes.Buffer:
		rdr = b
	default:
		raw, _ := json.Marshal(b)
		rdr = bytes.NewReader(raw)
		ct = "application/json"
	}
	req, _ := http.NewRequest(method, e.srv.URL+path, rdr)
	if ct != "" {
		req.Header.Set("Content-Type", ct)
	}
	if e.token != "" {
		req.Header.Set("Authorization", "Bearer "+e.token)
	}
	res, err := e.srv.Client().Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	if into != nil {
		defer res.Body.Close()
		if err := json.NewDecoder(res.Body).Decode(into); err != nil && err != io.EOF {
			e.t.Fatalf("%s %s: decode: %v", method, path, err)
		}
	}
	return res
}

func (e *testEnv) register() {
	e.t.Helper()
	var tr tokenResponse
	res := e.do("POST", "/api/auth/register", credentials{"reader", "secret123"}, &tr)
	if res.StatusCode != 200 {
		e.t.Fatalf("register: status %d", res.StatusCode)
	}
	e.token = tr.Token
}

func (e *testEnv) upload(title string, pages int) store.Book {
	e.t.Helper()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	mw.WriteField("title", title)
	mw.WriteField("page_count", fmt.Sprint(pages))
	fw, _ := mw.CreateFormFile("file", title+".pdf")
	fw.Write([]byte("%PDF-1.4\n%fake content\n%%EOF"))
	mw.Close()
	req, _ := http.NewRequest("POST", e.srv.URL+"/api/books", &buf)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.Header.Set("Authorization", "Bearer "+e.token)
	res, err := e.srv.Client().Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != 201 {
		raw, _ := io.ReadAll(res.Body)
		e.t.Fatalf("upload: status %d: %s", res.StatusCode, raw)
	}
	var b store.Book
	json.NewDecoder(res.Body).Decode(&b)
	return b
}

func TestRegistrationLockAndLogin(t *testing.T) {
	e := newEnv(t)

	var status map[string]any
	e.do("GET", "/api/status", nil, &status)
	if status["registered"] != false {
		t.Fatalf("expected registered=false, got %v", status)
	}

	e.register()

	e.do("GET", "/api/status", nil, &status)
	if status["registered"] != true {
		t.Fatalf("expected registered=true")
	}

	res := e.do("POST", "/api/auth/register", credentials{"other", "secret123"}, nil)
	if res.StatusCode != http.StatusConflict {
		t.Fatalf("second registration: expected 409, got %d", res.StatusCode)
	}

	e.token = ""
	res = e.do("POST", "/api/auth/login", credentials{"reader", "wrong"}, nil)
	if res.StatusCode != http.StatusUnauthorized {
		t.Fatalf("bad login: expected 401, got %d", res.StatusCode)
	}
	var tr tokenResponse
	res = e.do("POST", "/api/auth/login", credentials{"reader", "secret123"}, &tr)
	if res.StatusCode != 200 || tr.Token == "" {
		t.Fatalf("login failed: %d", res.StatusCode)
	}
	e.token = tr.Token
	var me store.User
	if res := e.do("GET", "/api/me", nil, &me); res.StatusCode != 200 || me.Username != "reader" {
		t.Fatalf("me: %d %+v", res.StatusCode, me)
	}
}

func TestLogoutRevokesToken(t *testing.T) {
	e := newEnv(t)
	e.register()
	first := e.token

	// A second login gets its own token; both work independently.
	var tr tokenResponse
	e.token = ""
	e.do("POST", "/api/auth/login", credentials{"reader", "secret123"}, &tr)
	second := tr.Token
	for _, tok := range []string{first, second} {
		e.token = tok
		if res := e.do("GET", "/api/me", nil, nil); res.StatusCode != 200 {
			t.Fatalf("token should be valid, got %d", res.StatusCode)
		}
	}

	// Logging out on one device only revokes that device's token.
	e.token = first
	if res := e.do("POST", "/api/auth/logout", nil, nil); res.StatusCode != http.StatusNoContent {
		t.Fatalf("logout: %d", res.StatusCode)
	}
	if res := e.do("GET", "/api/me", nil, nil); res.StatusCode != http.StatusUnauthorized {
		t.Fatalf("revoked token should be rejected, got %d", res.StatusCode)
	}
	e.token = second
	if res := e.do("GET", "/api/me", nil, nil); res.StatusCode != 200 {
		t.Fatalf("other device should stay signed in, got %d", res.StatusCode)
	}

	// logout-all revokes the rest.
	if res := e.do("POST", "/api/auth/logout-all", nil, nil); res.StatusCode != http.StatusNoContent {
		t.Fatalf("logout-all: %d", res.StatusCode)
	}
	if res := e.do("GET", "/api/me", nil, nil); res.StatusCode != http.StatusUnauthorized {
		t.Fatalf("token should be revoked after logout-all, got %d", res.StatusCode)
	}
}

func TestAuthMiddleware(t *testing.T) {
	e := newEnv(t)
	e.register()
	e.token = ""
	if res := e.do("GET", "/api/books", nil, nil); res.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401 without token, got %d", res.StatusCode)
	}
	e.token = "garbage"
	if res := e.do("GET", "/api/books", nil, nil); res.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401 with bad token, got %d", res.StatusCode)
	}
	// Non-API paths fall through to the web handler.
	res, _ := http.Get(e.srv.URL + "/some/spa/route")
	raw, _ := io.ReadAll(res.Body)
	if string(raw) != "web" {
		t.Fatalf("expected web handler, got %q", raw)
	}
}

func TestShelfRules(t *testing.T) {
	e := newEnv(t)
	e.register()

	var shelves []store.Shelf
	e.do("GET", "/api/shelves", nil, &shelves)
	if len(shelves) != 2 || shelves[0].Kind != store.ShelfActive || shelves[1].Kind != store.ShelfCompleted {
		t.Fatalf("expected predefined shelves, got %+v", shelves)
	}
	active := shelves[0]

	for _, sh := range shelves {
		if res := e.do("DELETE", fmt.Sprintf("/api/shelves/%d", sh.ID), nil, nil); res.StatusCode != http.StatusForbidden {
			t.Fatalf("delete predefined %s: expected 403, got %d", sh.Kind, res.StatusCode)
		}
		if res := e.do("PATCH", fmt.Sprintf("/api/shelves/%d", sh.ID), shelfBody{"x"}, nil); res.StatusCode != http.StatusForbidden {
			t.Fatalf("rename predefined %s: expected 403, got %d", sh.Kind, res.StatusCode)
		}
	}

	var custom store.Shelf
	if res := e.do("POST", "/api/shelves", shelfBody{"Sci-Fi"}, &custom); res.StatusCode != 201 || custom.Kind != store.ShelfCustom {
		t.Fatalf("create shelf: %d %+v", res.StatusCode, custom)
	}
	if res := e.do("PATCH", fmt.Sprintf("/api/shelves/%d", custom.ID), shelfBody{"Science Fiction"}, &custom); res.StatusCode != 200 || custom.Name != "Science Fiction" {
		t.Fatalf("rename shelf: %d %+v", res.StatusCode, custom)
	}

	// A book on the custom shelf moves to Active when the shelf is deleted.
	book := e.upload("Dune", 400)
	sid := custom.ID
	if res := e.do("PATCH", fmt.Sprintf("/api/books/%d", book.ID), bookPatchBody{ShelfID: &sid}, &book); res.StatusCode != 200 || book.ShelfID != custom.ID {
		t.Fatalf("move book: %d %+v", res.StatusCode, book)
	}
	if res := e.do("DELETE", fmt.Sprintf("/api/shelves/%d", custom.ID), nil, nil); res.StatusCode != http.StatusNoContent {
		t.Fatalf("delete custom shelf: %d", res.StatusCode)
	}
	e.do("GET", fmt.Sprintf("/api/books/%d", book.ID), nil, &book)
	if book.ShelfID != active.ID {
		t.Fatalf("expected book moved to active shelf %d, got %d", active.ID, book.ShelfID)
	}
}

func TestUploadDownloadAndProgress(t *testing.T) {
	e := newEnv(t)
	e.register()

	book := e.upload("Hyperion", 480)
	if book.Title != "Hyperion" || book.PageCount != 480 || book.SizeBytes == 0 {
		t.Fatalf("unexpected book %+v", book)
	}

	// Non-PDF payloads are rejected.
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	fw, _ := mw.CreateFormFile("file", "notes.txt")
	fw.Write([]byte("hello"))
	mw.Close()
	req, _ := http.NewRequest("POST", e.srv.URL+"/api/books", &buf)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.Header.Set("Authorization", "Bearer "+e.token)
	if res, _ := e.srv.Client().Do(req); res.StatusCode != http.StatusBadRequest {
		t.Fatalf("non-pdf upload: expected 400, got %d", res.StatusCode)
	}

	// Download streams the stored bytes with range support.
	req, _ = http.NewRequest("GET", fmt.Sprintf("%s/api/books/%d/file", e.srv.URL, book.ID), nil)
	req.Header.Set("Authorization", "Bearer "+e.token)
	req.Header.Set("Range", "bytes=0-4")
	res, _ := e.srv.Client().Do(req)
	raw, _ := io.ReadAll(res.Body)
	if res.StatusCode != http.StatusPartialContent || string(raw) != "%PDF-" {
		t.Fatalf("range download: %d %q", res.StatusCode, raw)
	}
	if ct := res.Header.Get("Content-Type"); !strings.HasPrefix(ct, "application/pdf") {
		t.Fatalf("content type %q", ct)
	}

	// Progress: newer timestamp wins, older is ignored.
	t1 := time.Now().Add(-time.Hour).UTC().Format(time.RFC3339Nano)
	t2 := time.Now().Add(-time.Minute).UTC().Format(time.RFC3339Nano)
	e.do("PUT", fmt.Sprintf("/api/books/%d/progress", book.ID), progressBody{CurrentPage: 120, PageOffset: 0.35, UpdatedAt: t2}, &book)
	if book.CurrentPage != 120 || book.PageOffset < 0.34 || book.PageOffset > 0.36 || book.LastReadAt == nil {
		t.Fatalf("progress not stored: %+v", book)
	}
	e.do("PUT", fmt.Sprintf("/api/books/%d/progress", book.ID), progressBody{CurrentPage: 50, PageOffset: 0.9, UpdatedAt: t1}, &book)
	if book.CurrentPage != 120 || book.PageOffset > 0.36 {
		t.Fatalf("stale progress overwrote newer one: %+v", book)
	}
	e.do("PUT", fmt.Sprintf("/api/books/%d/progress", book.ID), progressBody{CurrentPage: 200, UpdatedAt: ""}, &book)
	if book.CurrentPage != 200 {
		t.Fatalf("progress without timestamp should use now: %+v", book)
	}

	// Listing is filtered by shelf and ordered by recency.
	e.upload("Second", 10)
	var books []store.Book
	e.do("GET", "/api/books", nil, &books)
	if len(books) != 2 {
		t.Fatalf("expected 2 books, got %d", len(books))
	}
	e.do("GET", fmt.Sprintf("/api/books?shelf_id=%d", book.ShelfID), nil, &books)
	if len(books) != 2 {
		t.Fatalf("expected 2 books on active shelf, got %d", len(books))
	}

	// Delete removes row and file.
	if res := e.do("DELETE", fmt.Sprintf("/api/books/%d", book.ID), nil, nil); res.StatusCode != http.StatusNoContent {
		t.Fatalf("delete: %d", res.StatusCode)
	}
	if res := e.do("GET", fmt.Sprintf("/api/books/%d/file", book.ID), nil, nil); res.StatusCode != http.StatusNotFound {
		t.Fatalf("file after delete: expected 404, got %d", res.StatusCode)
	}
}

func TestSettings(t *testing.T) {
	e := newEnv(t)
	e.register()
	var st store.Settings
	e.do("GET", "/api/settings", nil, &st)
	if st.Zoom != 1 || st.Filter != "none" {
		t.Fatalf("defaults: %+v", st)
	}
	if res := e.do("PUT", "/api/settings", store.Settings{Zoom: 1.5, Filter: "neon"}, nil); res.StatusCode != http.StatusBadRequest {
		t.Fatalf("invalid filter: expected 400, got %d", res.StatusCode)
	}
	e.do("PUT", "/api/settings", store.Settings{Zoom: 1.5, Filter: "paper"}, nil)
	e.do("GET", "/api/settings", nil, &st)
	if st.Zoom != 1.5 || st.Filter != "paper" {
		t.Fatalf("settings not persisted: %+v", st)
	}
}
