// rollouts-demo is a tiny HTTP service used to make Argo Rollouts traffic
// shifting visible and measurable.
//
//   GET /            live tile grid, one tile per response, coloured by version
//   GET /api/color   the endpoint the grid polls; also where faults are injected
//   GET /metrics     Prometheus metrics the AnalysisTemplate queries
//   GET /healthz     readiness/liveness
//
// version, colour and the default fault settings are baked in at build time so
// that "v3 is a bad build" is a property of the image, not of the manifest.
package main

import (
	"encoding/json"
	"log"
	"math/rand"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Overridden at build time with -ldflags "-X main.version=v2 ...".
var (
	version          = "dev"
	color            = "#2563eb"
	defaultErrorRate = "0"
	defaultLatencyMs = "0"
)

var (
	errorRate int
	latencyMs int
	hostname  string

	requests = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "demo_http_requests_total",
		Help: "Total HTTP requests served, labelled by version and response code.",
	}, []string{"version", "path", "code"})

	duration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "demo_http_request_duration_seconds",
		Help:    "HTTP request latency in seconds.",
		Buckets: []float64{.005, .01, .025, .05, .1, .25, .5, 1, 2.5},
	}, []string{"version", "path"})
)

func envInt(key, fallback string) int {
	raw := os.Getenv(key)
	if raw == "" {
		raw = fallback
	}
	n, err := strconv.Atoi(raw)
	if err != nil {
		log.Printf("invalid %s=%q, using 0", key, raw)
		return 0
	}
	return n
}

// instrument records the metrics the canary analysis depends on.
func instrument(path string, next func(http.ResponseWriter) int) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		code := next(w)
		duration.WithLabelValues(version, path).Observe(time.Since(start).Seconds())
		requests.WithLabelValues(version, path, strconv.Itoa(code)).Inc()
	}
}

func colorHandler(w http.ResponseWriter) int {
	if latencyMs > 0 {
		time.Sleep(time.Duration(latencyMs) * time.Millisecond)
	}

	// Fault injection: errorRate is a percentage of requests that fail.
	if errorRate > 0 && rand.Intn(100) < errorRate {
		w.Header().Set("X-Demo-Version", version)
		http.Error(w, `{"error":"injected failure"}`, http.StatusInternalServerError)
		return http.StatusInternalServerError
	}

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Demo-Version", version)
	_ = json.NewEncoder(w).Encode(map[string]string{
		"version": version,
		"color":   color,
		"pod":     hostname,
	})
	return http.StatusOK
}

func main() {
	errorRate = envInt("ERROR_RATE", defaultErrorRate)
	latencyMs = envInt("LATENCY_MS", defaultLatencyMs)
	hostname, _ = os.Hostname()

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.Handler())
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("/api/color", instrument("/api/color", colorHandler))
	mux.HandleFunc("/", instrument("/", func(w http.ResponseWriter) int {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(indexHTML))
		return http.StatusOK
	}))

	log.Printf("rollouts-demo %s listening on :%s (error_rate=%d%% latency=%dms)",
		version, port, errorRate, latencyMs)

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Fatal(srv.ListenAndServe())
}
