// C-08 — the httprouter comparative study, as an executable corpus.
//
// -----------------------------------------------------------------------------
// ATTRIBUTION AND LICENCE
//
// The routing SCENARIOS below are adapted from the test suite of
// `julienschmidt/httprouter` (https://github.com/julienschmidt/httprouter),
// which is distributed under the BSD 3-Clause licence:
//
//   Copyright (c) 2013 Julien Schmidt. All rights reserved.
//
//   Redistribution and use in source and binary forms, with or without
//   modification, are permitted provided that the following conditions are met:
//
//   * Redistributions of source code must retain the above copyright notice,
//     this list of conditions and the following disclaimer.
//   * Redistributions in binary form must reproduce the above copyright notice,
//     this list of conditions and the following disclaimer in the documentation
//     and/or other materials provided with the distribution.
//   * The names of the contributors may not be used to endorse or promote
//     products derived from this software without specific prior written
//     permission.
//
//   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
//   AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
//   IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
//   ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
//   LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
//   CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
//   SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
//   INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
//   CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
//   ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
//   POSSIBILITY OF SUCH DAMAGE.
//
// No httprouter CODE is copied. What is adapted is the SHAPE OF ITS TEST CASES:
// which route sets are worth registering and which paths are worth asking about.
// -----------------------------------------------------------------------------
//
// WHY THIS IS A NEGATIVE CORPUS, and it is the whole point of C-08.
//
// The obvious thing to do with another router's tests is to check that you agree
// with it. That would be exactly wrong here. Uruquim's routing semantics differ
// from httprouter's DELIBERATELY, in three places, and each difference is a
// decision with a security or predictability argument behind it. So the corpus
// is run in order to prove that **every difference is intentional and pinned** —
// a regression toward httprouter's behaviour must fail this file.
//
// The three deliberate differences, each with its own section below:
//
//   1. PRECEDENCE. httprouter FORBIDS a static and a parameter route at the same
//      position ("conflicts with existing wildcard"). Uruquim allows both:
//      static wins, WITH CONTROLLED BACKTRACKING. `/users/me/settings` and
//      `/users/:id/profile` may coexist, and `/users/me/profile` must abandon
//      the static branch and succeed on the parameter branch. A literal port of
//      httprouter's tree would break this.
//
//   2. AUTOMATIC PATH CORRECTION. httprouter offers trailing-slash redirection
//      and case/`..`/`//` "path cleaning" that answers 301. Uruquim REJECTS and
//      never repairs: `/users` is not `/users/`, matching is case-sensitive, and
//      `..`, `.`, `//`, `%2F` and `%00` are refused BEFORE routing. A normaliser
//      that gets it wrong produces a path the check already approved — the
//      reason this is policy and not preference.
//
//   3. CATCH-ALL. httprouter has `*filepath`. Uruquim has no catch-all in the
//      router; static file serving is a MOUNT that owns its prefix entirely. A
//      catch-all is possibly useful later (gateways, SPA fallback) and is
//      evidence-gated, not forgotten.
//
// WHAT URUQUIM ALREADY HAS and need not borrow: automatic HEAD and OPTIONS, 405
// with a frozen-order `Allow`, alloc-free per-request params, and conflict
// diagnostics that refuse `/users/:id` beside `/users/:uid` at boot.
package test_c08_router_corpus

import "core:log"
import "core:strings"
import "core:testing"
import web "uruquim:web"

// A registration that can never serve is reported at Error level with a
// `uruquim:` prefix, and the pinned runner counts Error output as failure. This
// swallows exactly those and forwards the rest — the WP30 idiom, reused.
@(private = "file")
Quiet :: struct {
	inner: log.Logger,
}

@(private = "file")
quiet_logger_proc :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	record := (^Quiet)(data)
	if level == .Error && strings.contains(text, "uruquim:") {
		return
	}
	if record.inner.procedure != nil {
		record.inner.procedure(record.inner.data, level, text, options, location)
	}
}

@(private = "file")
quiet_logger :: proc(record: ^Quiet) -> log.Logger {
	record.inner = context.logger
	return log.Logger{quiet_logger_proc, record, context.logger.lowest_level, context.logger.options}
}

@(private = "file")
ok :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "ok")
}

// ---------------------------------------------------------------------------
// 1. Overlapping prefixes — httprouter's canonical radix stress, and Uruquim
//    must agree here. This is the POSITIVE half: where the two routers have no
//    reason to differ, agreeing is evidence the tree is right.
// ---------------------------------------------------------------------------

@(test)
c08_overlapping_static_prefixes_each_resolve_to_themselves :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	// Adapted from httprouter's tree test: prefixes that are prefixes of each
	// other, registered in an order that would break a naive trie.
	for route in ([?]string{"/", "/cmd", "/c", "/co", "/con", "/contact", "/cona", "/single"}) {
		web.get(&app, route, ok)
	}

	for route in ([?]string{"/", "/cmd", "/c", "/co", "/con", "/contact", "/cona", "/single"}) {
		res := web.test_request(&app, .GET, route)
		testing.expectf(t, res.status == .OK, "%s must resolve to itself, got %v", route, res.status)
	}
	// A prefix that was never registered is a miss, not a nearest-match.
	for miss in ([?]string{"/cont", "/conta", "/sing", "/cmdx", "/cn"}) {
		res := web.test_request(&app, .GET, miss)
		testing.expectf(
			t,
			res.status == .Not_Found,
			"%s was never registered and must 404 rather than resolve to a prefix, got %v",
			miss,
			res.status,
		)
	}
}

@(test)
c08_deep_and_multi_parameter_paths_resolve :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	// Adapted from httprouter's deep-path and multi-param cases.
	web.get(&app, "/a/b/c/d/e/f/g/h/i/j", ok)
	web.get(&app, "/src/:owner/:repo/blob/:branch", ok)
	web.get(&app, "/info/:user/project/:project", ok)

	for path in ([?]string{
		"/a/b/c/d/e/f/g/h/i/j",
		"/src/uruquim/core/blob/main",
		"/info/gordon/project/go",
	}) {
		res := web.test_request(&app, .GET, path)
		testing.expectf(t, res.status == .OK, "%s must resolve, got %v", path, res.status)
	}
	// A parameter never matches ACROSS a separator: that is what makes a segment
	// router a segment router.
	res := web.test_request(&app, .GET, "/src/uruquim/core/extra/blob/main")
	testing.expectf(
		t,
		res.status == .Not_Found,
		"a parameter must not swallow a separator, got %v",
		res.status,
	)
}

@(test)
c08_unicode_routes_resolve_by_bytes :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	// httprouter's Unicode cases. Uruquim matches BYTES, never normalised code
	// points, so an identical byte sequence resolves and a canonically
	// equivalent but differently encoded one does not — which is the same
	// no-normalisation rule as everywhere else, applied to routing.
	web.get(&app, "/café", ok)
	web.get(&app, "/日本語/:id", ok)

	for path in ([?]string{"/café", "/日本語/42"}) {
		res := web.test_request(&app, .GET, path)
		testing.expectf(t, res.status == .OK, "%s must resolve by bytes, got %v", path, res.status)
	}
}

// ---------------------------------------------------------------------------
// 2. THE FIRST DELIBERATE DIFFERENCE — precedence with backtracking.
//
//    httprouter refuses this route set outright. Uruquim accepts it and must
//    backtrack, and this test is the pin: a compact-radix experiment
//    (`radix_compact`, the deferred half of C-08) that ported httprouter's tree
//    literally would fail HERE, which is exactly the alarm it should trip.
// ---------------------------------------------------------------------------

@(test)
c08_static_wins_but_the_router_backtracks_to_the_parameter :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/users/me/settings", ok)
	web.get(&app, "/users/:id/profile", ok)

	// The static branch wins where it is complete.
	res := web.test_request(&app, .GET, "/users/me/settings")
	testing.expectf(t, res.status == .OK, "the static route must win, got %v", res.status)

	// THE BACKTRACK. `/users/me/profile` enters the static branch at `me`, finds
	// no `profile` under it, and must ABANDON that branch and retry `:id`.
	// httprouter cannot express this route set at all; a tree that commits to
	// the static branch would 404 here.
	res = web.test_request(&app, .GET, "/users/me/profile")
	testing.expectf(
		t,
		res.status == .OK,
		"the router must backtrack from the static branch to the parameter branch, got %v",
		res.status,
	)

	// And the parameter branch serves anything else in that position.
	res = web.test_request(&app, .GET, "/users/42/profile")
	testing.expectf(t, res.status == .OK, "the parameter branch must serve, got %v", res.status)

	// A path under neither is still a miss.
	res = web.test_request(&app, .GET, "/users/me/avatar")
	testing.expectf(
		t,
		res.status == .Not_Found,
		"backtracking must not invent a match, got %v",
		res.status,
	)
}

@(test)
c08_two_differently_named_parameters_in_one_position_are_refused :: proc(t: ^testing.T) {
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/users/:id", ok)
	web.get(&app, "/users/:uid", ok) // the conflict: one slot, two spellings

	// httprouter panics at registration. Uruquim is fail-closed instead: the App
	// is poisoned and every request answers 500, so the failure is a boot-time
	// symptom a developer reads rather than a runtime condition to route around
	// (ADR-019, WP30).
	res := web.test_request(&app, .GET, "/users/42")
	testing.expectf(
		t,
		res.status == .Internal_Server_Error,
		"a parameter-name conflict must poison the App, got %v",
		res.status,
	)
}

// ---------------------------------------------------------------------------
// 3. THE SECOND DELIBERATE DIFFERENCE — no automatic path correction.
//
//    These are the cases httprouter answers with a 301 redirect. Uruquim
//    answers 404 or 400 and never rewrites. Each assertion here is a REFUSAL TO
//    ADOPT a feature, and this file exists so that adopting one by accident
//    fails the build.
// ---------------------------------------------------------------------------

@(test)
c08_a_trailing_slash_is_a_different_path_and_is_never_redirected :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/users", ok)
	web.get(&app, "/posts/", ok)

	res := web.test_request(&app, .GET, "/users")
	testing.expectf(t, res.status == .OK, "/users must serve, got %v", res.status)

	// httprouter would answer 301 to /users. Uruquim answers 404: `/users/` is a
	// different path, and a redirect is a rewrite the security policy forbids.
	res = web.test_request(&app, .GET, "/users/")
	testing.expectf(
		t,
		res.status == .Not_Found,
		"/users/ must NOT be redirected to /users — no automatic path correction, got %v",
		res.status,
	)

	// And symmetrically, in the direction httprouter also corrects.
	res = web.test_request(&app, .GET, "/posts")
	testing.expectf(
		t,
		res.status == .Not_Found,
		"/posts must NOT be redirected to /posts/, got %v",
		res.status,
	)
}

@(test)
c08_case_is_significant_and_is_never_fixed :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/users", ok)

	// httprouter's CleanPath/case-insensitive lookup would find this. Uruquim
	// does not: a router that repairs case is a router where two spellings reach
	// one handler and an audit log has to guess which one the client sent.
	for variant in ([?]string{"/Users", "/USERS", "/uSeRs"}) {
		res := web.test_request(&app, .GET, variant)
		testing.expectf(
			t,
			res.status == .Not_Found,
			"%s must NOT be case-corrected to /users, got %v",
			variant,
			res.status,
		)
	}
}

@(test)
c08_dot_segments_and_empty_segments_are_rejected_before_routing :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/users", ok)
	web.get(&app, "/users/:id", ok)

	// httprouter's CleanPath would resolve every one of these to /users and
	// answer 301. Uruquim REJECTS before the router ever sees them — a rejection
	// cannot produce a path the check already approved, which a normaliser can.
	for hostile in ([?]string{
		"/users/../users",
		"/users/./x",
		"//users",
		"/users//",
		"/users/%2e%2e/admin",
		"/users/%2Fadmin",
	}) {
		res := web.test_request(&app, .GET, hostile)
		testing.expectf(
			t,
			res.status == .Bad_Request || res.status == .Not_Found,
			"%s must be refused, never cleaned into a match (got %v)",
			hostile,
			res.status,
		)
	}
}

// ---------------------------------------------------------------------------
// 4. THE THIRD DELIBERATE DIFFERENCE — no catch-all.
// ---------------------------------------------------------------------------

@(test)
c08_there_is_no_catch_all_wildcard :: proc(t: ^testing.T) {
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/files/:name", ok)

	// httprouter's `/files/*filepath` would match a multi-segment tail. Uruquim
	// has no such syntax: a parameter is one segment, and multi-segment serving
	// is a `mount`, which owns its prefix and applies the static-file security
	// rules. A request with a deeper tail is a miss, not a capture.
	res := web.test_request(&app, .GET, "/files/a/b/c")
	testing.expectf(
		t,
		res.status == .Not_Found,
		"a parameter must not behave as a catch-all, got %v",
		res.status,
	)

	res = web.test_request(&app, .GET, "/files/report.pdf")
	testing.expectf(t, res.status == .OK, "the single-segment parameter must serve, got %v", res.status)
}

// ---------------------------------------------------------------------------
// 5. Method collection — where Uruquim already does MORE than httprouter, and
//    the corpus records it so the comparison is honest in both directions.
// ---------------------------------------------------------------------------

@(test)
c08_method_collection_answers_405_with_a_frozen_order_allow :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/thing", ok)
	web.post(&app, "/thing", ok)
	web.delete(&app, "/thing", ok)

	res := web.test_request(&app, .PUT, "/thing")
	testing.expectf(
		t,
		res.status == .Method_Not_Allowed,
		"a known path with an unregistered method must be 405, not 404, got %v",
		res.status,
	)

	allow := ""
	for line in res.headers {
		if strings.has_prefix(strings.to_lower(line, context.temp_allocator), "allow:") {
			allow = strings.trim_space(line[len("Allow:"):])
		}
	}
	// The ORDER is frozen: registration-independent and not alphabetical, so
	// two applications registering the same methods in different sequences
	// produce byte-identical headers. A set rendered in map order would make
	// this header non-deterministic, and a non-deterministic header is one no
	// client or cache can rely on.
	//
	// AMENDED BY AUDIT R8, and the amendment is a correction to this comment as
	// much as to the assertion. The note here used to read: "this assertion was
	// written wrong the first time — as an alphabetical list including HEAD and
	// OPTIONS — and the corpus caught it", filed as a lesson about importing
	// another system's expectations.
	//
	// TWO THINGS WERE CONFLATED IN THAT REJECTION. The alphabetical ordering
	// was genuinely wrong and stays rejected. Listing HEAD and OPTIONS was
	// RIGHT, and was thrown out with it. Measured on a socket against a
	// GET-only route: HEAD answers 200 and OPTIONS answers 204, while `Allow`
	// said `GET`. RFC 9110 §10.2.1 defines the field as the set of methods the
	// resource supports, so the header was describing what an application had
	// typed rather than what the server does.
	//
	// The framework's two automatic verbs are now named: HEAD directly after
	// GET (it IS the GET route — `implicit_from_token` maps it before matching,
	// so a path without GET has no HEAD), and OPTIONS last and unconditional
	// (`options_answer` answers any path that gets this far).
	testing.expectf(
		t,
		allow == "GET, HEAD, POST, DELETE, OPTIONS",
		"Allow must be the frozen order GET, [HEAD], POST, PUT, PATCH, DELETE, OPTIONS — the registered methods plus the two the framework serves itself (audit R8) — got %q",
		allow,
	)
}
