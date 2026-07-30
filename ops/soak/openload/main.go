// Command openload is a fixed-rate HTTP generator for this repository's soak and
// application-load work.
//
// Latency starts at the request's intended schedule time, not when a worker
// eventually obtains it. This includes generator/backlog delay and therefore
// does not hide coordinated omission. It is a control for the closed-loop wrk
// matrix, not a replacement for a separately validated load generator.
//
// DIAGNOSABILITY (planning/diagnosability.md). The previous version of this
// program counted a failed request as `err: true` and dropped the error value,
// so a 12-hour soak recorded 674 transport errors and could not say what one of
// them was. Every failure here carries its cause:
//
//   - the error is CLASSIFIED into a closed taxonomy, so a new failure mode
//     surfaces as "unclassified" rather than melting into a generic bucket;
//   - the error TEXT is preserved verbatim;
//   - every sample carries ABSOLUTE unix nanoseconds, so a failure can be
//     correlated with server counters and kernel counters from the same run;
//   - connection reuse and Go's silent retries are recorded, because a request
//     that failed once and succeeded on a retry used to count as a clean
//     success.
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptrace"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// failureClass is the closed taxonomy. A cause that matches nothing becomes
// classUnclassified, which the analyser treats as a FAILING result: an
// unexplained anomaly is exactly what this program exists to prevent.
type failureClass string

const (
	classNone          failureClass = ""
	classDialRefused   failureClass = "dial_refused"
	classDialTimeout   failureClass = "dial_timeout"
	classDialOther     failureClass = "dial_other"
	classReset         failureClass = "peer_reset"
	classEOFReused     failureClass = "eof_on_reused_conn"
	classEOFFresh      failureClass = "eof_on_fresh_conn"
	classHeaderTimeout failureClass = "response_header_timeout"
	classTotalTimeout  failureClass = "client_timeout"
	classWriteFailed   failureClass = "request_write_failed"
	classBodyRead      failureClass = "response_body_read"
	classBodyClose     failureClass = "response_body_close"
	classBrokenPipe    failureClass = "broken_pipe"
	classRequestBuild  failureClass = "request_build"
	classUnclassified  failureClass = "unclassified"
)

type sample struct {
	// scheduled/sent/done are absolute, so any sample can be joined against
	// server /stats snapshots and kernel counters by timestamp.
	scheduledUnixNanos int64
	sentUnixNanos      int64
	doneUnixNanos      int64
	latency            time.Duration
	lag                time.Duration
	status             int
	bodyBytes          int64
	connReused         bool
	connWasIdle        bool
	dialCount          int // >1 means Go retried on a new connection
	wroteRequest       bool
	class              failureClass
	errText            string
}

func (s sample) failed() bool { return s.class != classNone }

type classCount struct {
	Class   string `json:"class"`
	Count   int    `json:"count"`
	Example string `json:"example_error"`
}

type summary struct {
	URL             string  `json:"url"`
	Method          string  `json:"method"`
	RatePerSecond   int     `json:"rate_per_second"`
	DurationSeconds float64 `json:"duration_seconds"`
	Connections     int     `json:"connections"`
	TimeoutSeconds  float64 `json:"timeout_seconds"`

	StartedUnixNanos int64  `json:"started_unix_nanos"`
	StartedUTC       string `json:"started_utc"`
	EndedUnixNanos   int64  `json:"ended_unix_nanos"`
	EndedUTC         string `json:"ended_utc"`

	Planned         int            `json:"planned"`
	Completed       int            `json:"completed"`
	Succeeded       int            `json:"succeeded"`
	TransportErrors int            `json:"transport_errors"`
	Status          map[string]int `json:"status"`

	// Failures is the whole point: every error class that occurred, with a
	// verbatim example. Empty when the run had no failure.
	Failures     []classCount `json:"failures"`
	Unclassified int          `json:"unclassified"`

	// Connection accounting. Retries were invisible before: a request that
	// failed once and succeeded on a second connection counted as a success.
	ConnReused   int `json:"conn_reused"`
	ConnFresh    int `json:"conn_fresh"`
	ExtraDials   int `json:"extra_dials"`
	WroteRequest int `json:"wrote_request"`

	AchievedPerSecond  float64 `json:"achieved_per_second"`
	GoodputPerSecond   float64 `json:"goodput_per_second"`
	LatencyP50Micros   int64   `json:"latency_p50_us"`
	LatencyP90Micros   int64   `json:"latency_p90_us"`
	LatencyP99Micros   int64   `json:"latency_p99_us"`
	LatencyP999Micros  int64   `json:"latency_p999_us"`
	LatencyMaxMicros   int64   `json:"latency_max_us"`
	SchedulerP99Micros int64   `json:"scheduler_lag_p99_us"`
	SchedulerMaxMicros int64   `json:"scheduler_lag_max_us"`
	CompletionSeconds  float64 `json:"completion_window_seconds"`
	ResponseBytes      int64   `json:"response_bytes"`
}

func percentile(values []time.Duration, fraction float64) time.Duration {
	if len(values) == 0 {
		return 0
	}
	index := int(float64(len(values)-1) * fraction)
	return values[index]
}

// classify maps a Go client error onto the taxonomy. Order matters: the
// specific syscall and net cases are tested before the generic string cases,
// and anything unrecognised is reported as unclassified rather than guessed.
func classify(err error, phase string, reused bool, wrote bool) (failureClass, string) {
	text := err.Error()

	var netErr net.Error
	timedOut := errors.As(err, &netErr) && netErr.Timeout()

	switch {
	case errors.Is(err, syscall.ECONNREFUSED):
		return classDialRefused, text
	case errors.Is(err, syscall.ECONNRESET):
		return classReset, text
	case errors.Is(err, syscall.EPIPE):
		return classBrokenPipe, text
	}

	if phase == "dial" {
		if timedOut {
			return classDialTimeout, text
		}
		return classDialOther, text
	}

	if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) ||
		strings.Contains(text, "EOF") {
		if reused {
			return classEOFReused, text
		}
		return classEOFFresh, text
	}

	if timedOut {
		// Go reports the response-header deadline with this exact phrase; the
		// whole-request deadline reports "Client.Timeout exceeded".
		if strings.Contains(text, "timeout awaiting response headers") {
			return classHeaderTimeout, text
		}
		return classTotalTimeout, text
	}

	if !wrote {
		return classWriteFailed, text
	}
	return classUnclassified, text
}

func mediumPayload() []byte {
	var body bytes.Buffer
	body.WriteString(`{"request_id":"req-0123456789abcdef","items":[`)
	for index := 1; index <= 64; index++ {
		if index > 1 {
			body.WriteByte(',')
		}
		fmt.Fprintf(
			&body,
			`{"id":%d,"name":"item-%02d-abcdefghijklmnop","score":%d.5,"active":true}`,
			index,
			index,
			index,
		)
	}
	body.WriteString(`],"tags":["alpha","beta","gamma","delta","epsilon","zeta"]}`)
	return body.Bytes()
}

func runRSTCampaign(target string, count, concurrency int, delay time.Duration) error {
	parsed, err := url.Parse(target)
	if err != nil {
		return err
	}
	if parsed.Scheme != "http" || parsed.Host == "" {
		return fmt.Errorf("RST campaign requires an http URL with a host")
	}
	path := parsed.RequestURI()
	if path == "" {
		path = "/"
	}
	host := parsed.Host
	address := host
	if !strings.Contains(address, ":") {
		address += ":80"
	}
	request := []byte(fmt.Sprintf(
		"GET %s HTTP/1.1\r\nHost: %s\r\nConnection: keep-alive\r\n\r\n",
		path,
		host,
	))

	started := time.Now()
	jobs := make(chan struct{})
	type campaignFailure struct {
		phase string
		text  string
	}
	failures := make(chan campaignFailure, count)
	var workers sync.WaitGroup
	workers.Add(concurrency)
	for range concurrency {
		go func() {
			defer workers.Done()
			for range jobs {
				conn, dialErr := net.DialTimeout("tcp", address, 2*time.Second)
				if dialErr != nil {
					failures <- campaignFailure{"dial", dialErr.Error()}
					continue
				}
				tcp, ok := conn.(*net.TCPConn)
				if !ok {
					_ = conn.Close()
					failures <- campaignFailure{"assert", "connection is not TCP"}
					continue
				}
				_ = tcp.SetLinger(0)
				_ = tcp.SetWriteDeadline(time.Now().Add(2 * time.Second))
				_, writeErr := tcp.Write(request)
				if writeErr == nil {
					time.Sleep(delay)
				}
				closeErr := tcp.Close()
				if writeErr != nil {
					failures <- campaignFailure{"write", writeErr.Error()}
				} else if closeErr != nil {
					failures <- campaignFailure{"close", closeErr.Error()}
				}
			}
		}()
	}
	go func() {
		for range count {
			jobs <- struct{}{}
		}
		close(jobs)
	}()
	workers.Wait()
	close(failures)

	byPhase := map[string]int{}
	examples := map[string]string{}
	total := 0
	for failure := range failures {
		total++
		byPhase[failure.phase]++
		if _, seen := examples[failure.phase]; !seen {
			examples[failure.phase] = failure.text
		}
	}
	ended := time.Now()

	// This campaign is DELIBERATE fault injection. Its report is separate from
	// the load report on purpose, so the analyser can subtract the resets it
	// caused from the failures the framework produced on its own.
	report := map[string]any{
		"mode":               "rst-after-write",
		"deliberate":         true,
		"url":                target,
		"attempted":          count,
		"concurrency":        concurrency,
		"delay_ms":           delay.Milliseconds(),
		"errors":             total,
		"errors_by_phase":    byPhase,
		"examples_by_phase":  examples,
		"started_unix_nanos": started.UnixNano(),
		"started_utc":        started.UTC().Format(time.RFC3339Nano),
		"ended_unix_nanos":   ended.UnixNano(),
		"ended_utc":          ended.UTC().Format(time.RFC3339Nano),
	}
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	return encoder.Encode(report)
}

func main() {
	var (
		target      = flag.String("url", "", "complete target URL")
		method      = flag.String("method", "GET", "HTTP method")
		rate        = flag.Int("rate", 100, "fixed requests per second")
		duration    = flag.Duration("duration", 20*time.Second, "schedule duration")
		connections = flag.Int("connections", 128, "maximum concurrent connections/workers")
		timeout     = flag.Duration("timeout", 10*time.Second, "per-request timeout")
		payloadName = flag.String("payload", "", "empty or medium-json")
		rawPath     = flag.String("raw", "", "per-request CSV; every failure keeps its cause")
		rstCount    = flag.Int("rst-count", 0, "raw TCP requests reset after write")
		rstDelay    = flag.Duration("rst-delay", 25*time.Millisecond, "delay before RST")
	)
	flag.Parse()
	if *target == "" || *connections <= 0 {
		flag.Usage()
		os.Exit(2)
	}
	if *rstCount > 0 {
		if err := runRSTCampaign(
			*target,
			*rstCount,
			*connections,
			*rstDelay,
		); err != nil {
			fmt.Fprintf(os.Stderr, "RST campaign: %v\n", err)
			os.Exit(1)
		}
		return
	}
	if *rate <= 0 || *duration <= 0 {
		flag.Usage()
		os.Exit(2)
	}

	var payload []byte
	switch *payloadName {
	case "":
	case "medium-json":
		payload = mediumPayload()
	default:
		fmt.Fprintf(os.Stderr, "unknown payload %q\n", *payloadName)
		os.Exit(2)
	}

	transport := &http.Transport{
		Proxy:                 nil,
		DialContext:           (&net.Dialer{Timeout: *timeout, KeepAlive: 30 * time.Second}).DialContext,
		ForceAttemptHTTP2:     false,
		MaxIdleConns:          *connections,
		MaxIdleConnsPerHost:   *connections,
		MaxConnsPerHost:       *connections,
		IdleConnTimeout:       30 * time.Second,
		ResponseHeaderTimeout: *timeout,
		DisableCompression:    true,
	}
	client := &http.Client{Transport: transport, Timeout: *timeout}
	defer transport.CloseIdleConnections()

	planned := int(float64(*rate) * duration.Seconds())
	jobs := make(chan time.Time, *connections*2)
	samples := make(chan sample, *connections*2)
	var workers sync.WaitGroup
	workers.Add(*connections)
	for range *connections {
		go func() {
			defer workers.Done()
			for scheduled := range jobs {
				// Per-request trace. `reused` and `dials` are what make a
				// silent retry visible; `wrote` separates "we never got the
				// request out" from "we got no answer to it".
				var (
					reused bool
					idle   bool
					dials  int
					wrote  bool
					phase  = "connect"
				)
				trace := &httptrace.ClientTrace{
					GetConn: func(string) { phase = "connect" },
					ConnectStart: func(string, string) {
						dials++
						phase = "dial"
					},
					GotConn: func(info httptrace.GotConnInfo) {
						reused = info.Reused
						idle = info.WasIdle
						phase = "request"
					},
					WroteRequest: func(info httptrace.WroteRequestInfo) {
						if info.Err == nil {
							wrote = true
							phase = "response"
						}
					},
				}

				started := time.Now()
				request, err := http.NewRequest(*method, *target, bytes.NewReader(payload))
				if err != nil {
					done := time.Now()
					samples <- sample{
						scheduledUnixNanos: scheduled.UnixNano(),
						sentUnixNanos:      started.UnixNano(),
						doneUnixNanos:      done.UnixNano(),
						lag:                started.Sub(scheduled),
						latency:            done.Sub(scheduled),
						class:              classRequestBuild,
						errText:            err.Error(),
					}
					continue
				}
				request = request.WithContext(httptrace.WithClientTrace(request.Context(), trace))
				request.Close = false
				if len(payload) > 0 {
					request.Header.Set("Content-Type", "application/json")
				}

				response, err := client.Do(request)
				if err != nil {
					done := time.Now()
					class, text := classify(err, phase, reused, wrote)
					samples <- sample{
						scheduledUnixNanos: scheduled.UnixNano(),
						sentUnixNanos:      started.UnixNano(),
						doneUnixNanos:      done.UnixNano(),
						lag:                started.Sub(scheduled),
						latency:            done.Sub(scheduled),
						connReused:         reused,
						connWasIdle:        idle,
						dialCount:          dials,
						wroteRequest:       wrote,
						class:              class,
						errText:            text,
					}
					continue
				}

				read, copyErr := io.Copy(io.Discard, response.Body)
				closeErr := response.Body.Close()
				done := time.Now()
				result := sample{
					scheduledUnixNanos: scheduled.UnixNano(),
					sentUnixNanos:      started.UnixNano(),
					doneUnixNanos:      done.UnixNano(),
					lag:                started.Sub(scheduled),
					latency:            done.Sub(scheduled),
					status:             response.StatusCode,
					bodyBytes:          read,
					connReused:         reused,
					connWasIdle:        idle,
					dialCount:          dials,
					wroteRequest:       wrote,
				}
				if copyErr != nil {
					result.class, result.errText = classBodyRead, copyErr.Error()
				} else if closeErr != nil {
					result.class, result.errText = classBodyClose, closeErr.Error()
				}
				samples <- result
			}
		}()
	}

	results := make([]sample, 0, planned)
	var collector sync.WaitGroup
	collector.Add(1)
	go func() {
		defer collector.Done()
		for result := range samples {
			results = append(results, result)
		}
	}()

	scheduleStart := time.Now().Add(250 * time.Millisecond)
	for index := 0; index < planned; index++ {
		scheduled := scheduleStart.Add(time.Duration(int64(index) * int64(time.Second) / int64(*rate)))
		if wait := time.Until(scheduled); wait > 0 {
			time.Sleep(wait)
		}
		jobs <- scheduled
	}
	close(jobs)
	workers.Wait()
	close(samples)
	collector.Wait()
	ended := time.Now()
	completionWindow := ended.Sub(scheduleStart)

	latencies := make([]time.Duration, 0, len(results))
	lags := make([]time.Duration, 0, len(results))
	statuses := make(map[string]int)
	byClass := make(map[failureClass]int)
	exampleOf := make(map[failureClass]string)
	var (
		failed, succeeded, reusedCount, freshCount, extraDials, wroteCount int
		responseBytes                                                      int64
	)
	for _, result := range results {
		latencies = append(latencies, result.latency)
		lags = append(lags, result.lag)
		statuses[strconv.Itoa(result.status)]++
		responseBytes += result.bodyBytes
		if result.connReused {
			reusedCount++
		} else {
			freshCount++
		}
		if result.dialCount > 1 {
			extraDials += result.dialCount - 1
		}
		if result.wroteRequest {
			wroteCount++
		}
		if result.failed() {
			failed++
			byClass[result.class]++
			if _, seen := exampleOf[result.class]; !seen {
				exampleOf[result.class] = result.errText
			}
		} else {
			succeeded++
		}
	}
	sort.Slice(latencies, func(i, j int) bool { return latencies[i] < latencies[j] })
	sort.Slice(lags, func(i, j int) bool { return lags[i] < lags[j] })

	failures := make([]classCount, 0, len(byClass))
	for class, count := range byClass {
		failures = append(failures, classCount{
			Class:   string(class),
			Count:   count,
			Example: exampleOf[class],
		})
	}
	sort.Slice(failures, func(i, j int) bool { return failures[i].Count > failures[j].Count })

	if *rawPath != "" {
		raw, err := os.Create(*rawPath)
		if err != nil {
			fmt.Fprintf(os.Stderr, "create raw output: %v\n", err)
			os.Exit(1)
		}
		fmt.Fprintln(raw, "scheduled_unix_nanos,sent_unix_nanos,done_unix_nanos,"+
			"latency_ns,scheduler_lag_ns,status,body_bytes,conn_reused,conn_was_idle,"+
			"dial_count,wrote_request,failure_class,error_text")
		for _, result := range results {
			fmt.Fprintf(raw, "%d,%d,%d,%d,%d,%d,%d,%t,%t,%d,%t,%s,%s\n",
				result.scheduledUnixNanos, result.sentUnixNanos, result.doneUnixNanos,
				result.latency, result.lag, result.status, result.bodyBytes,
				result.connReused, result.connWasIdle, result.dialCount,
				result.wroteRequest, result.class, csvQuote(result.errText))
		}
		if err := raw.Close(); err != nil {
			fmt.Fprintf(os.Stderr, "close raw output: %v\n", err)
			os.Exit(1)
		}
	}

	// Failures also go to stderr, which the orchestrator captures per workload.
	// The previous version left 1,283 .err files at zero bytes because nothing
	// ever wrote to them.
	if failed > 0 {
		for _, entry := range failures {
			fmt.Fprintf(os.Stderr, "failure class=%s count=%d example=%q\n",
				entry.Class, entry.Count, entry.Example)
		}
	}

	report := summary{
		URL:              *target,
		Method:           *method,
		RatePerSecond:    *rate,
		DurationSeconds:  duration.Seconds(),
		Connections:      *connections,
		TimeoutSeconds:   timeout.Seconds(),
		StartedUnixNanos: scheduleStart.UnixNano(),
		StartedUTC:       scheduleStart.UTC().Format(time.RFC3339Nano),
		EndedUnixNanos:   ended.UnixNano(),
		EndedUTC:         ended.UTC().Format(time.RFC3339Nano),

		Planned:         planned,
		Completed:       len(results),
		Succeeded:       succeeded,
		TransportErrors: failed,
		Status:          statuses,
		Failures:        failures,
		Unclassified:    byClass[classUnclassified],

		ConnReused:   reusedCount,
		ConnFresh:    freshCount,
		ExtraDials:   extraDials,
		WroteRequest: wroteCount,

		AchievedPerSecond:  float64(len(results)) / completionWindow.Seconds(),
		GoodputPerSecond:   float64(succeeded) / completionWindow.Seconds(),
		LatencyP50Micros:   percentile(latencies, .50).Microseconds(),
		LatencyP90Micros:   percentile(latencies, .90).Microseconds(),
		LatencyP99Micros:   percentile(latencies, .99).Microseconds(),
		LatencyP999Micros:  percentile(latencies, .999).Microseconds(),
		LatencyMaxMicros:   percentile(latencies, 1).Microseconds(),
		SchedulerP99Micros: percentile(lags, .99).Microseconds(),
		SchedulerMaxMicros: percentile(lags, 1).Microseconds(),
		CompletionSeconds:  completionWindow.Seconds(),
		ResponseBytes:      responseBytes,
	}
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(report); err != nil {
		fmt.Fprintf(os.Stderr, "encode summary: %v\n", err)
		os.Exit(1)
	}
}

// csvQuote keeps an error message on one CSV field. Error text carries commas
// and quotes, and a raw log that cannot be parsed is a log that will not be
// read.
func csvQuote(text string) string {
	if text == "" {
		return ""
	}
	return `"` + strings.ReplaceAll(text, `"`, `""`) + `"`
}
