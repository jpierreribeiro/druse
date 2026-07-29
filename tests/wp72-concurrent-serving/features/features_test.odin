package wp72_features

import "core:strings"
import "core:testing"
import "core:time"
import lab "druse:tests/support/web_blocking_lab"
import web "druse:web"

STATIC_DIR :: "tests/wp72-concurrent-serving/fixture"
BOUNDARY :: "----wp72boundary"
FORM_BODY :: "--" + BOUNDARY + "\r\n" +
	"Content-Disposition: form-data; name=\"title\"\r\n\r\n" +
	"a report\r\n" +
	"--" + BOUNDARY + "\r\n" +
	"Content-Disposition: form-data; name=\"doc\"; filename=\"notes.txt\"\r\n" +
	"Content-Type: text/plain\r\n\r\n" +
	"hello file\r\n" +
	"--" + BOUNDARY + "--"

@(private)
int_string :: proc(n: int) -> string {
	buffer: [24]u8
	i := len(buffer)
	value := n
	if value == 0 {return strings.clone("0")}
	for value > 0 {
		i -= 1
		buffer[i] = u8('0' + value % 10)
		value /= 10
	}
	return strings.clone(string(buffer[i:]))
}

@(private)
probe :: proc(t: ^testing.T, s: ^lab.Server, request: string, status: int, facts: ..string) {
	actual, raw, ok := lab.Raw_Request(s.port, request)
	defer if len(raw) > 0 {delete(raw)}
	testing.expectf(t, ok && actual == status, "wire status: got %d, want %d", actual, status)
	for fact in facts {
		lower_raw := strings.to_lower(raw, context.temp_allocator)
		lower_fact := strings.to_lower(fact, context.temp_allocator)
		testing.expectf(t, strings.contains(lower_raw, lower_fact), "response %q missing %q", raw, fact)
	}
}

@(test)
phase5_features_and_http_semantics_remain_live_with_three_blocked_handlers :: proc(t: ^testing.T) {
	s: lab.Server
	blocked: [3]lab.Call
	defer {
		lab.Stop(&s)
		for &call in blocked {lab.Join_Call(&call)}
	}
	limits := web.DEFAULT_LIMITS
	limits.max_handlers = 4
	testing.expect(t, lab.Start_With_Features(&s, 51076, limits, STATIC_DIR))

	for &call in blocked {
		lab.Start_Call(&call, s.port, "/block")
		testing.expect(t, lab.Wait_Entered(&s))
	}

	probe(
		t, &s,
		"GET /health HTTP/1.1\r\nHost: localhost\r\nOrigin: https://app.example.com\r\nConnection: close\r\n\r\n",
		200,
		"Access-Control-Allow-Origin: https://app.example.com",
		"X-Request-ID:",
		"ok",
	)
	probe(
		t, &s,
		"OPTIONS /health HTTP/1.1\r\nHost: localhost\r\nOrigin: https://app.example.com\r\nAccess-Control-Request-Method: GET\r\nConnection: close\r\n\r\n",
		204,
		"Access-Control-Allow-Methods: GET, POST",
	)
	probe(
		t, &s,
		"GET /assets/app.js HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
		200,
		"console.log('wp72')",
		"ETag:",
	)

	length := int_string(len(FORM_BODY))
	defer delete(length)
	post := strings.concatenate({
		"POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Type: multipart/form-data; boundary=",
		BOUNDARY,
		"\r\nContent-Length: ", length,
		"\r\nConnection: close\r\n\r\n", FORM_BODY,
	})
	defer delete(post)
	probe(t, &s, post, 200, "upload", "X-Request-ID:")

	probe(
		t, &s,
		"GET /missing HTTP/1.1\r\nHost: localhost\r\nOrigin: https://app.example.com\r\nConnection: close\r\n\r\n",
		404,
		"not_found",
		"Access-Control-Allow-Origin: https://app.example.com",
	)
	probe(
		t, &s,
		"POST /health HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
		405,
		"Allow: GET",
	)

	testing.expect(t, lab.Middleware_Hits(&s) >= 8, "requests that dispatch through the app must retain middleware")
	lab.Release(&s, len(blocked))
	for &call in blocked {testing.expect(t, lab.Wait_Call(&call, 2 * time.Second))}
}
