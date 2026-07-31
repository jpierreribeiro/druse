// The fasthttp peer, added 2026-07-30.
//
// WHY IT EXISTS. README.md's headline performance claim is "Druse delivered
// 91.7% of fasthttp at c100 and 96.6% at c400" — and the paragraph directly
// under that table says the number cannot be regenerated from the checkout,
// because `bench/framework_ping/` holds no fasthttp peer, no orchestration and
// no raw output. The project's most-quoted comparison rested on a table nobody
// could reproduce.
//
// Fiber is in this matrix and Fiber runs ON fasthttp, but Fiber is not
// fasthttp: it adds routing, a context abstraction and its own JSON encoder
// (sonic). Reading Fiber's row as fasthttp's would be the same substitution the
// withdrawn `/json/medium` row was withdrawn for.
//
// So this is fasthttp itself — the same v1.72.0 the Fiber build already pins,
// promoted from an indirect dependency to a direct one so the version cannot
// drift between the two rows — routed by hand, encoding with encoding/json
// exactly as the net/http peer does. What it measures is the server, not a
// framework's encoder.
package main

import (
	"encoding/json"
	"net/http"
	"os"
	"strconv"
	"sync/atomic"

	"github.com/valyala/fasthttp"

	"druse-bench/application-matrix-go/workload"
)

func writeJSON(ctx *fasthttp.RequestCtx, status int, value any) {
	ctx.SetStatusCode(status)
	ctx.SetContentType("application/json")
	if err := json.NewEncoder(ctx).Encode(value); err != nil {
		ctx.SetStatusCode(http.StatusInternalServerError)
	}
}

// encoding/json's Encoder appends a newline; the other peers use Marshal and do
// not. A trailing byte would show up as a response-size difference and the
// summariser would flag the whole row as not like-for-like — correctly. Marshal
// keeps the bytes identical to the net/http peer's.
func writeJSONExact(ctx *fasthttp.RequestCtx, status int, value any) {
	body, err := json.Marshal(value)
	if err != nil {
		ctx.SetStatusCode(http.StatusInternalServerError)
		return
	}
	ctx.SetStatusCode(status)
	ctx.SetContentType("application/json")
	ctx.SetBody(body)
}

func main() {
	var requestID atomic.Uint64

	handler := func(ctx *fasthttp.RequestCtx) {
		path := string(ctx.Path())
		method := string(ctx.Method())

		switch {
		case method == "GET" && path == "/health":
			ctx.SetContentType("text/plain; charset=utf-8")
			ctx.SetBodyString("ok")

		case method == "GET" && path == "/json/small":
			writeJSONExact(ctx, http.StatusOK, workload.Small)

		case method == "GET" && path == "/json/medium":
			writeJSONExact(ctx, http.StatusOK, workload.Medium)

		case method == "GET" && path == "/json/medium/int":
			writeJSONExact(ctx, http.StatusOK, workload.MediumInt)

		case method == "POST" && path == "/json/echo":
			var input workload.SmallDocument
			if err := workload.DecodeStrict(ctx.PostBody(), &input); err != nil {
				writeJSONExact(ctx, http.StatusBadRequest, map[string]string{"error": "invalid_json"})
				return
			}
			writeJSONExact(ctx, http.StatusOK, input)

		case method == "POST" && path == "/json/medium":
			var input workload.MediumDocument
			if err := workload.DecodeStrict(ctx.PostBody(), &input); err != nil {
				writeJSONExact(ctx, http.StatusBadRequest, map[string]string{"error": "invalid_json"})
				return
			}
			writeJSONExact(ctx, http.StatusOK, input)

		case method == "POST" && path == "/json/medium/decode":
			var input workload.MediumDocument
			if err := workload.DecodeStrict(ctx.PostBody(), &input); err != nil {
				writeJSONExact(ctx, http.StatusBadRequest, map[string]string{"error": "invalid_json"})
				return
			}
			ctx.SetStatusCode(http.StatusNoContent)

		default:
			// /api/users/:id — the extract endpoint. Hand-routed, because the
			// point of this peer is fasthttp's server loop without a router in
			// front of it.
			if method == "GET" && len(path) > len("/api/users/") &&
				path[:len("/api/users/")] == "/api/users/" {
				id := requestID.Add(1)
				ctx.Response.Header.Set("X-Request-Id", strconv.FormatUint(id, 10))

				response, err := workload.ParseRouted(
					path[len("/api/users/"):],
					string(ctx.QueryArgs().Peek("verbose")),
					7, // the account id the other peers put in their context
				)
				if err != nil {
					writeJSONExact(ctx, http.StatusBadRequest,
						map[string]string{"error": "invalid_field"})
					return
				}
				writeJSONExact(ctx, http.StatusOK, response)
				return
			}
			ctx.SetStatusCode(http.StatusNotFound)
		}
	}

	address := ":8081"
	if len(os.Args) > 1 {
		address = ":" + os.Args[1]
	}

	server := &fasthttp.Server{
		Handler: handler,
		Name:    "fasthttp-matrix-peer",
	}
	if err := server.ListenAndServe(address); err != nil {
		panic(err)
	}
}
