// WP20 — THE TYPED FRAMEWORK-ERROR OBSERVER: `observe` and `Framework_Event`.
//
// ADR-011 promised a Phase-2 typed observer: one closed event, never `any`, no
// change to the handler shape. ADR-026 (option A) fixed the field set, and
// this file delivers it.
//
// WHAT AN OBSERVER CAN SEE, AND WHY THAT IS THE POINT. An observer receives a
// `Framework_Event` BY VALUE and receives NOTHING ELSE — no `^Context`, no
// body, no headers. That is not a convenience; it is the redaction constraint
// of §6.2 expressed as a type:
//
//   * it cannot respond, so it can never produce a second write (the §6.3
//     clause about the commit guard holds a fortiori — there is nothing to
//     write through);
//   * it cannot reach a request byte the event does not carry;
//   * it cannot dangle: the event is a value, and its only `string` field is
//     `route`, which is either a static constant or an App-owned pattern that
//     lives until `destroy`.
//
// The event carries LOW-CARDINALITY route identity — the registered pattern —
// and never the raw path, per the OpenTelemetry HTTP conventions: `http.route`
// MUST be low-cardinality and MUST NOT be populated when the framework cannot
// supply it. On a miss there is no route, so `route` is `""` — populated by
// nothing, never by the path. No field carries a message string: the six
// compile-time diagnostics stay in the log, so no request byte can reach an
// observer through a formatted line either.
package web
// druse:file application

// Framework_Event is the one closed event a framework-detected failure
// produces. It is passed to the observer BY VALUE.
//
// FIELD SET (ADR-026 A, and the gate pins it — `build/check_public_api.sh`
// asserts this exact list and that no field other than `route` is a `string`,
// so a future `path: string` fails the build):
//
//   * `kind`         — which failure, from the closed `Framework_Error` set;
//   * `method`       — the request method, or `.UNKNOWN` for a failure that
//                      belongs to no request (the `serve` path);
//   * `route`        — the REGISTERED PATTERN the request matched, owned by
//                      the App and valid until `destroy`; `""` when no route
//                      matched and for failures outside a request;
//   * `status`       — the status the framework committed for this failure,
//                      read AFTER the commit so it is the truth rather than a
//                      prediction; the zero value when the failure produced no
//                      response at all (again, the `serve` path);
//   * `payload_type` — the offending type as a `typeid`, never the value. The
//                      value may be exactly the thing that could not be
//                      marshalled, and storing it would put an `any` on a
//                      framework path (ADR-011 forbids it).
Framework_Event :: struct {
	kind:         Framework_Error,
	method:       Method,
	route:        string,
	status:       Status,
	payload_type: typeid,
}

// observe registers the application's framework-error observer.
//
// ONE observer per App; a later `observe` REPLACES the earlier one (last
// wins). A list would add an allocation and an ordering question for no
// evidenced need.
//
// Every framework-detected failure is observed exactly once, after the
// diagnostic is logged and at the commit that answers it, identically on both
// transports — the emission sits on the shared request pipeline and on
// `serve`, not in one driver. Registering no observer leaves behaviour
// bit-for-bit as it was: the failure is still logged and still answered the
// same way. `bare()` installs none, because `bare()` installs nothing.
//
// WHAT AN OBSERVER IS FOR: exporting framework failures to metrics, tracing or
// an alerting pipeline. It is NOT an error handler — it cannot change the
// response, and the framework has already decided what to answer by the time
// it runs.
//
// It allocates nothing: the observer is one procedure pointer on the App, and
// the event is a value.
observe :: proc(a: ^App, observer: proc(event: Framework_Event)) {
	if app_is_serving(a) {
		app_reject_late_configuration(a)
		return
	}
	a.private.observer = observer
}

// framework_observe_request emits the event for a failure that happened INSIDE
// a request, reading the request's own identity from the Context: the method,
// the matched pattern (empty on a miss) and the status that was actually
// committed.
//
// It is called at each report site AFTER the framework has committed its
// answer, which is what makes `status` truthful. The observer pointer is
// copied onto the Context by the driver at the start of the request, so this
// path needs no `^App` — the back-pointer `Context_Internal` deliberately does
// not have (WP4 D3) stays absent.
@(private)
framework_observe_request :: proc(payload_type: typeid, ctx: ^Context, kind: Framework_Error) {
	if ctx.private.observer == nil {
		return
	}
	ctx.private.observer(
		Framework_Event {
			kind = kind,
			method = ctx.request.method,
			route = ctx.private.route,
			status = ctx.private.response.status,
			payload_type = payload_type,
		},
	)
}

// framework_observe_app emits the event for a failure that belongs to NO
// request — the `serve` path: an invalid port, a bind/listen failure, or a
// refusal to start a fail-closed application.
//
// `method`, `route` and `status` keep their zero values on purpose: there was
// no request and no response, and inventing values would be worse than saying
// nothing (§6.2 — a field the framework cannot supply is not populated).
@(private)
framework_observe_app :: proc(payload_type: typeid, a: ^App, kind: Framework_Error) {
	if a.private.observer == nil {
		return
	}
	a.private.observer(Framework_Event{kind = kind, payload_type = payload_type})
}
