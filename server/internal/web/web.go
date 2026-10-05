// Package web serves the embedded Flutter web build.
//
// The build output of `flutter build web` is copied into ./dist by `make web`.
// When the directory only contains the .gitkeep placeholder the handler
// answers with a short notice instead of the app.
package web

import (
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"io/fs"
	"net/http"
	"path"
	"strings"
)

//go:embed all:dist
var distFS embed.FS

// Handler returns an http.Handler that serves the Flutter build with SPA
// fallback: any path that does not match a file is answered with index.html so
// client-side routing keeps working on refresh.
func Handler() http.Handler {
	sub, err := fs.Sub(distFS, "dist")
	if err != nil {
		panic(err)
	}
	if _, err := fs.Stat(sub, "index.html"); err != nil {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte("Dusty Library API is running, but the web UI was not bundled.\nRun `make web` before building the server.\n"))
		})
	}
	etags := computeETags(sub)
	fileServer := http.FileServerFS(sub)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		p := strings.TrimPrefix(path.Clean(r.URL.Path), "/")
		if p == "" {
			p = "index.html"
		}
		if _, err := fs.Stat(sub, p); err != nil {
			// Unknown path: serve the SPA shell.
			r.URL.Path = "/"
			p = "index.html"
		}
		// The entry scripts are also renamed per build (see the Makefile), because
		// a browser that cached the first main.dart.js for a day will not ask
		// again while that entry is fresh. Every file is still revalidated:
		// If-None-Match yields a 304 while the build is unchanged.
		w.Header().Set("Cache-Control", "no-cache")
		if tag, ok := etags[p]; ok {
			w.Header().Set("ETag", tag)
		}
		fileServer.ServeHTTP(w, r)
	})
}

// computeETags hashes every file in the build once at startup. The bundle is a
// few megabytes, so this is negligible, and it gives http.FileServer the
// validators it needs to answer conditional requests.
func computeETags(fsys fs.FS) map[string]string {
	tags := map[string]string{}
	_ = fs.WalkDir(fsys, ".", func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		b, err := fs.ReadFile(fsys, p)
		if err != nil {
			return nil
		}
		sum := sha256.Sum256(b)
		tags[p] = `"` + hex.EncodeToString(sum[:16]) + `"`
		return nil
	})
	return tags
}
