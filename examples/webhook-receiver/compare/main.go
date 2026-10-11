// The same webhook receiver in Go's standard library, for comparison with
// app.pl. No framework: net/http with Go 1.22's method-aware patterns.
//
// Run:  WEBHOOK_SECRET=s3cret go run main.go
package main

import (
	"bufio"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"time"
)

var secret = []byte(env("WEBHOOK_SECRET", "s3cret"))
var logPath = env("WEBHOOK_LOG", "/tmp/deliveries.jsonl")

func env(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

type delivery struct {
	ID       string          `json:"id"`
	Event    string          `json:"event"`
	Received int64           `json:"received"`
	Payload  json.RawMessage `json:"payload"`
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func signatureOK(r *http.Request, raw []byte) bool {
	given := r.Header.Get("X-Hub-Signature-256")
	if given == "" {
		return false
	}
	mac := hmac.New(sha256.New, secret)
	mac.Write(raw)
	want := "sha256=" + hex.EncodeToString(mac.Sum(nil))
	return hmac.Equal([]byte(given), []byte(want))
}

func deliveries() []delivery {
	f, err := os.Open(logPath)
	if err != nil {
		return nil
	}
	defer f.Close()
	var out []delivery
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		var d delivery
		if json.Unmarshal(sc.Bytes(), &d) == nil {
			out = append(out, d)
		}
	}
	return out
}

func receive(w http.ResponseWriter, r *http.Request) {
	raw, _ := io.ReadAll(r.Body)
	if !signatureOK(r, raw) {
		writeJSON(w, 401, map[string]string{"error": "bad signature"})
		return
	}
	if !json.Valid(raw) {
		http.Error(w, "The request body is not valid JSON.", 400)
		return
	}
	id := r.Header.Get("X-GitHub-Delivery")
	if id == "" {
		id = strconv.FormatInt(time.Now().Unix(), 10)
	}
	event := r.Header.Get("X-GitHub-Event")
	if event == "" {
		event = "unknown"
	}
	d := delivery{ID: id, Event: event, Received: time.Now().Unix(), Payload: raw}
	f, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	defer f.Close()
	json.NewEncoder(f).Encode(d)
	writeJSON(w, 202, map[string]any{"ok": 1, "id": id})
}

func statusPage(w http.ResponseWriter, r *http.Request) {
	all := deliveries()
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprintf(w, "<h1>Webhook receiver</h1>\n<p>%d deliveries logged to <code>%s</code>.</p>\n<ul>", len(all), logPath)
	for i := len(all) - 1; i >= 0 && i >= len(all)-10; i-- {
		d := all[i]
		fmt.Fprintf(w, "<li><code>%s</code> %s <small>%s</small></li>", d.Event, d.ID, time.Unix(d.Received, 0).Format(time.ANSIC))
	}
	fmt.Fprint(w, "</ul>\n<p><a href=\"/deliveries.json\">JSON</a></p>\n")
}

func deliveriesJSON(w http.ResponseWriter, r *http.Request) {
	all := deliveries()
	n, err := strconv.Atoi(r.URL.Query().Get("n"))
	if err != nil || n <= 0 || n > len(all) {
		n = min(50, len(all))
	}
	if all == nil {
		all = []delivery{}
	}
	writeJSON(w, 200, all[len(all)-n:])
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /hooks/github", receive)
	mux.HandleFunc("GET /{$}", statusPage)
	mux.HandleFunc("GET /deliveries.json", deliveriesJSON)
	http.ListenAndServe(":8000", mux)
}
