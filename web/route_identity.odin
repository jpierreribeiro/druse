// WP34 — ROUTE IDENTITY: `route`.
//
// One symbol, and the whole design question is which STRING it returns.
//
// THE ANSWER IS THE PATTERN, NEVER THE PATH. `/users/:id`, not `/users/42`.
// That is not a preference about formatting; it is C-2's constraint, the same
// one `Framework_Event.route` was built under (WP20): the OpenTelemetry HTTP
// conventions require `http.route` to be LOW-CARDINALITY, because a metric
// keyed on the raw path has one time series per user id — which is how a
// metrics backend falls over, and how a user identifier ends up in a dashboard
// nobody meant to put it in. A framework that hands out the path here would be
// handing out the shape of the mistake.
//
// The rule has a gate assertion of its own (`build/check_public_api.sh`),
// alongside the one that keeps `Framework_Event` free of request strings. Two
// procedures could otherwise drift apart while both looking correct.
//
// WHY THE NAME IS `route` AND NOT `route_pattern`, `matched_route` or
// `route_name`. G-01: one question, one name. The framework already calls this
// value `route` — it is the `route` field of `Framework_Event`, populated from
// the same slot, carrying the same string. An accessor with a second name would
// mean an application reading `web.route(ctx)` and an observer reading
// `event.route` had to be told they are the same thing.
//
// WHY IT EXISTS AT ALL, given that Phase 1 refused it (OQ-18 called an accessor
// "FUTURE"). An application cannot otherwise label its own metrics, logs or
// traces by route: the pattern is known to the framework and to nobody else,
// and `ctx.request.path` is precisely the wrong substitute. The framework
// already holds the value, so the cost is one procedure and no storage.
package web
// druse:file application

// route returns the REGISTERED PATTERN this request matched — `"/users/:id"`,
// never `"/users/42"` — or `""` when no route matched.
//
// An empty result is the honest answer and not an error: on a 404 there is no
// route, and the OpenTelemetry rule is that a field the framework cannot supply
// is left unpopulated rather than filled with a guess. Callers labelling
// telemetry should treat `""` as the "unmatched" bucket, which is exactly the
// low-cardinality thing they want.
//
// LIFETIME: the result is a VIEW over App-owned storage — the pattern the App
// cloned at registration — so it is valid until `destroy`, which outlives the
// request. It is the same exception the lifetime ledger already records for
// `Framework_Event.route`, and the only value reachable from a `^Context` that
// is not request-scoped. Copy it anyway if it must outlive the App.
//
// It allocates nothing and reads one field.
route :: proc(ctx: ^Context) -> string {
	return ctx.private.route
}
