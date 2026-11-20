package webui

import (
	"embed"
	"net/http"
)

//go:embed index.html app.js app.css
var files embed.FS

func Serve(w http.ResponseWriter, r *http.Request) {
	name := "index.html"
	if r.URL.Path == "/app.js" {
		name = "app.js"
		w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
	} else if r.URL.Path == "/app.css" {
		name = "app.css"
		w.Header().Set("Content-Type", "text/css; charset=utf-8")
	} else {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
	}
	b, e := files.ReadFile(name)
	if e != nil {
		http.Error(w, "unavailable", 500)
		return
	}
	w.Write(b)
}
