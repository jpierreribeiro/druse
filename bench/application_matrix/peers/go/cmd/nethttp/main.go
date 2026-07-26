package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"strconv"
	"sync/atomic"

	"uruquim-bench/application-matrix-go/workload"
)

type contextKey string

const accountIDKey contextKey = "account_id"

func main() {
	mux := http.NewServeMux()
	var requestID atomic.Uint64
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = io.WriteString(w, "ok")
	})
	mux.HandleFunc("GET /json/small", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, workload.Small)
	})
	mux.HandleFunc("GET /json/medium", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, workload.Medium)
	})
	mux.HandleFunc("POST /json/echo", func(w http.ResponseWriter, r *http.Request) {
		var input workload.SmallDocument
		if err := decodeBody(r, &input); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_json"})
			return
		}
		writeJSON(w, http.StatusOK, input)
	})
	mux.HandleFunc("POST /json/medium", func(w http.ResponseWriter, r *http.Request) {
		var input workload.MediumDocument
		if err := decodeBody(r, &input); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_json"})
			return
		}
		writeJSON(w, http.StatusOK, input)
	})
	mux.HandleFunc("POST /json/medium/decode", func(w http.ResponseWriter, r *http.Request) {
		var input workload.MediumDocument
		if err := decodeBody(r, &input); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_json"})
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
	mux.Handle(
		"GET /api/users/{id}",
		withRequestID(&requestID, noop(noop(withAuth(routedHandler())))),
	)
	address := ":8081"
	if len(os.Args) > 1 {
		address = ":" + os.Args[1]
	}
	if err := http.ListenAndServe(address, mux); err != nil {
		panic(err)
	}
}

func decodeBody(r *http.Request, dst any) error {
	raw, err := io.ReadAll(r.Body)
	if err != nil {
		return err
	}
	return workload.DecodeStrict(raw, dst)
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	data, err := json.Marshal(value)
	if err != nil {
		http.Error(w, "internal_error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_, _ = w.Write(data)
}

func routedHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		accountID, _ := r.Context().Value(accountIDKey).(int)
		response, err := workload.ParseRouted(r.PathValue("id"), r.URL.Query().Get("verbose"), accountID)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_field"})
			return
		}
		writeJSON(w, http.StatusOK, response)
	})
}

func withRequestID(counter *atomic.Uint64, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Request-Id", strconv.FormatUint(counter.Add(1), 10))
		next.ServeHTTP(w, r)
	})
}

func noop(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		next.ServeHTTP(w, r)
	})
}

func withAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), accountIDKey, 7)))
	})
}
