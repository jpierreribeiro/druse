// WP28 — the route representation shootout: the candidates.
//
// RG-2 names five representations to measure, plus the linear table Phase 2
// actually ships as the baseline they must beat, plus one added afterwards to
// settle the node-interior question WP28 left open:
//
//   linear            what `web/dispatch_table.odin` does today
//   linear_improved   the same scan with a cheap prefilter before full compare
//   bucketed          static / parametric split at registration, RG-2's addition
//   radix_ptr         segment-keyed tree, children behind pointers
//   radix_idx         the same tree, nodes in a flat array, children by index
//   hybrid            a map for whole static paths, linear for the rest
//   radix_arr         radix_idx with sorted-array children instead of a map
//
// WHY SEGMENT-GRAINED AND NOT BYTE-GRAINED. A byte-level radix is the textbook
// answer, and it is the wrong granularity for this framework: Druse's
// patterns are segment structures (`/users/:id`), precedence is defined per
// segment ("static routes win over parametric ones"), and a byte tree would
// have to reconstruct segment boundaries it deliberately erased. Measuring the
// wrong shape precisely is still measuring the wrong shape.
//
// WHAT EVERY CANDIDATE MUST DO IDENTICALLY, because a shootout whose entrants
// disagree about the work measures error rate and calls it performance:
//
//   * a static route beats a parametric one at the same path;
//   * exactly one `:param` per pattern (WP4's dispatcher stores more as given
//     and never matches it, and WP33 is where that changes);
//   * a miss returns ok = false, never a wrong route;
//   * the captured parameter value is a VIEW into the request path, never a
//     copy — G-05, and a candidate that cloned would be buying its speed with
//     an allocation nobody asked for.
//
// `equivalence.odin` proves that agreement rather than assuming it, and the
// runner refuses to report a timing for a candidate that fails it.
package shootout_support

import "core:strings"

// MAX_SEGMENTS bounds a pattern and a path at matching time.
//
// Fixed capacity rather than a dynamic array, and the reason is the thing under
// measurement: a per-request allocation inside a matcher would be measured as
// part of that candidate's cost and would beat every honest candidate to a
// slower answer. 16 is well past anything a real route table uses; a path with
// more segments simply does not match, which is the fail-closed answer.
MAX_SEGMENTS :: 16

// Route is one registered pattern, pre-split at build time.
//
// Splitting at registration rather than at lookup is not a candidate's clever
// idea, it is the project's stated rule: "If work can be done at registration
// time, do it then." Every candidate gets the same head start, so the shootout
// measures the representation and not who remembered to precompute.
Route :: struct {
	pattern:     string,
	segments:    [MAX_SEGMENTS]string,
	count:       int,
	// -1 for a fully static route, otherwise the index of the one `:param`.
	param_index: int,
	// Cheap discriminants the improved-linear candidate prefilters on.
	first_byte:  u8,
	total_len:   int,
}

Match :: struct {
	route: int,
	param: string,
	ok:    bool,
}

MISS :: Match{route = -1, param = "", ok = false}

// ---------------------------------------------------------------------------
// Shared path handling. Allocation-free, and used identically by every
// candidate so no candidate can win on a cheaper splitter.
// ---------------------------------------------------------------------------

Segments :: struct {
	seg:   [MAX_SEGMENTS]string,
	count: int,
	valid: bool,
}

// split_path walks a path into segments without allocating.
//
// A leading slash is required and its empty first field is skipped. A trailing
// slash produces a trailing EMPTY segment and is preserved as such: `/users`
// and `/users/` are different paths, which is Phase 1's ratified behaviour and
// which WP31a has now confirmed permanently.
split_path :: proc(path: string) -> (out: Segments) {
	if len(path) == 0 || path[0] != '/' {
		return
	}
	start := 1
	for i := 1; i <= len(path); i += 1 {
		if i == len(path) || path[i] == '/' {
			if out.count >= MAX_SEGMENTS {
				out.count = 0
				return
			}
			out.seg[out.count] = path[start:i]
			out.count += 1
			start = i + 1
		}
	}
	out.valid = true
	return
}

route_make :: proc(pattern: string, index: int) -> (r: Route, ok: bool) {
	parts := split_path(pattern)
	if !parts.valid {
		return {}, false
	}
	r.pattern = pattern
	r.count = parts.count
	r.param_index = -1
	r.total_len = len(pattern)
	if len(pattern) > 1 {
		r.first_byte = pattern[1]
	}
	for i in 0 ..< parts.count {
		r.segments[i] = parts.seg[i]
		if len(parts.seg[i]) > 0 && parts.seg[i][0] == ':' {
			r.param_index = i
		}
	}
	return r, true
}

// route_try matches one pre-split route against pre-split path segments.
//
// Every candidate that reaches a leaf calls THIS, so the per-route comparison
// cost is identical across the shootout and the only thing that differs is how
// many routes each candidate has to reach.
@(private = "file")
route_try :: proc(r: ^Route, p: ^Segments) -> (param: string, ok: bool) {
	if r.count != p.count {
		return "", false
	}
	for i in 0 ..< r.count {
		if i == r.param_index {
			// A parametric segment matches any NON-EMPTY segment. An empty one
			// would make `/users/` match `/users/:id` with an empty id, which
			// is a silent surprise rather than a route.
			if len(p.seg[i]) == 0 {
				return "", false
			}
			param = p.seg[i]
			continue
		}
		if r.segments[i] != p.seg[i] {
			return "", false
		}
	}
	return param, true
}

// ---------------------------------------------------------------------------
// CANDIDATE 1 — linear. The baseline: what Phase 2 ships.
// ---------------------------------------------------------------------------

Linear :: struct {
	routes: [dynamic]Route,
}

linear_build :: proc(t: ^Linear, patterns: []string) -> bool {
	routes, err := make([dynamic]Route, 0, len(patterns))
	if err != nil {
		return false
	}
	t.routes = routes
	for pattern, i in patterns {
		r, ok := route_make(pattern, i)
		if !ok {
			return false
		}
		append(&t.routes, r)
	}
	return true
}

linear_destroy :: proc(t: ^Linear) {
	delete(t.routes)
	t.routes = nil
}

// Two passes, because static must beat parametric and a single pass over a
// mixed array would return whichever came first in registration order.
linear_match :: proc(t: ^Linear, path: string) -> Match {
	p := split_path(path)
	if !p.valid {
		return MISS
	}
	for &r, i in t.routes {
		if r.param_index >= 0 {
			continue
		}
		if param, ok := route_try(&r, &p); ok {
			return Match{route = i, param = param, ok = true}
		}
	}
	for &r, i in t.routes {
		if r.param_index < 0 {
			continue
		}
		if param, ok := route_try(&r, &p); ok {
			return Match{route = i, param = param, ok = true}
		}
	}
	return MISS
}

// ---------------------------------------------------------------------------
// CANDIDATE 2 — improved linear. Same scan, cheap rejection first.
// ---------------------------------------------------------------------------

Linear_Improved :: struct {
	routes: [dynamic]Route,
}

linear_improved_build :: proc(t: ^Linear_Improved, patterns: []string) -> bool {
	routes, err := make([dynamic]Route, 0, len(patterns))
	if err != nil {
		return false
	}
	t.routes = routes
	for pattern, i in patterns {
		r, ok := route_make(pattern, i)
		if !ok {
			return false
		}
		append(&t.routes, r)
	}
	return true
}

linear_improved_destroy :: proc(t: ^Linear_Improved) {
	delete(t.routes)
	t.routes = nil
}

// The prefilter is segment count plus the first byte after the leading slash —
// two integer comparisons that reject most routes before any string compare.
// For a fully static route the total length is a third free discriminant.
linear_improved_match :: proc(t: ^Linear_Improved, path: string) -> Match {
	p := split_path(path)
	if !p.valid {
		return MISS
	}
	first: u8 = 0
	if len(path) > 1 {
		first = path[1]
	}

	for &r, i in t.routes {
		if r.param_index >= 0 || r.count != p.count || r.first_byte != first {
			continue
		}
		if r.total_len != len(path) {
			continue
		}
		if param, ok := route_try(&r, &p); ok {
			return Match{route = i, param = param, ok = true}
		}
	}
	for &r, i in t.routes {
		if r.param_index < 0 || r.count != p.count {
			continue
		}
		// The first byte is only a discriminant when the first segment is not
		// the parameter itself.
		if r.param_index != 0 && r.first_byte != first {
			continue
		}
		if param, ok := route_try(&r, &p); ok {
			return Match{route = i, param = param, ok = true}
		}
	}
	return MISS
}

// ---------------------------------------------------------------------------
// CANDIDATE 3 — class-bucketed linear (RG-2's addition).
//
// It is worth measuring for a reason that has nothing to do with speed: it
// makes the precedence rule between static and parametric STRUCTURAL rather
// than re-derived by comparison order. RG-2 attaches its own disclaimer, and it
// stands: the bucketed design still scans linearly inside each bucket.
// ---------------------------------------------------------------------------

Bucketed :: struct {
	static_routes: [dynamic]Route,
	param_routes:  [dynamic]Route,
	static_index:  [dynamic]int,
	param_index:   [dynamic]int,
}

bucketed_build :: proc(t: ^Bucketed, patterns: []string) -> bool {
	t.static_routes = make([dynamic]Route, 0, len(patterns)) or_else nil
	t.param_routes = make([dynamic]Route, 0, len(patterns)) or_else nil
	t.static_index = make([dynamic]int, 0, len(patterns)) or_else nil
	t.param_index = make([dynamic]int, 0, len(patterns)) or_else nil
	for pattern, i in patterns {
		r, ok := route_make(pattern, i)
		if !ok {
			return false
		}
		if r.param_index < 0 {
			append(&t.static_routes, r)
			append(&t.static_index, i)
		} else {
			append(&t.param_routes, r)
			append(&t.param_index, i)
		}
	}
	return true
}

bucketed_destroy :: proc(t: ^Bucketed) {
	delete(t.static_routes)
	delete(t.param_routes)
	delete(t.static_index)
	delete(t.param_index)
	t.static_routes = nil
	t.param_routes = nil
	t.static_index = nil
	t.param_index = nil
}

bucketed_match :: proc(t: ^Bucketed, path: string) -> Match {
	p := split_path(path)
	if !p.valid {
		return MISS
	}
	// Precedence is the bucket order itself; no second pass, no ordering rule
	// to re-derive.
	for &r, i in t.static_routes {
		if param, ok := route_try(&r, &p); ok {
			return Match{route = t.static_index[i], param = param, ok = true}
		}
	}
	for &r, i in t.param_routes {
		if param, ok := route_try(&r, &p); ok {
			return Match{route = t.param_index[i], param = param, ok = true}
		}
	}
	return MISS
}

// ---------------------------------------------------------------------------
// CANDIDATE 4 — hybrid: a map for whole static paths, linear for the rest.
//
// The static half becomes O(1); the parametric half stays a scan. Worth
// measuring because real route tables are mostly static, and because the
// idiom guide's warning about maps in hot dispatch deserves a number rather
// than a repetition.
// ---------------------------------------------------------------------------

Hybrid :: struct {
	static_map:   map[string]int,
	param_routes: [dynamic]Route,
	param_index:  [dynamic]int,
}

hybrid_build :: proc(t: ^Hybrid, patterns: []string) -> bool {
	t.static_map = make(map[string]int)
	t.param_routes = make([dynamic]Route, 0, len(patterns)) or_else nil
	t.param_index = make([dynamic]int, 0, len(patterns)) or_else nil
	for pattern, i in patterns {
		r, ok := route_make(pattern, i)
		if !ok {
			return false
		}
		if r.param_index < 0 {
			t.static_map[pattern] = i
		} else {
			append(&t.param_routes, r)
			append(&t.param_index, i)
		}
	}
	return true
}

hybrid_destroy :: proc(t: ^Hybrid) {
	delete(t.static_map)
	delete(t.param_routes)
	delete(t.param_index)
	t.static_map = nil
	t.param_routes = nil
	t.param_index = nil
}

hybrid_match :: proc(t: ^Hybrid, path: string) -> Match {
	// The static lookup is a whole-path hash, so it needs no split at all.
	if idx, found := t.static_map[path]; found {
		return Match{route = idx, param = "", ok = true}
	}
	p := split_path(path)
	if !p.valid {
		return MISS
	}
	for &r, i in t.param_routes {
		if param, ok := route_try(&r, &p); ok {
			return Match{route = t.param_index[i], param = param, ok = true}
		}
	}
	return MISS
}

// ---------------------------------------------------------------------------
// CANDIDATE 5 — pointer-based radix, keyed by segment.
// ---------------------------------------------------------------------------

Radix_Ptr_Node :: struct {
	children:    map[string]^Radix_Ptr_Node,
	param_child: ^Radix_Ptr_Node,
	route:       int,
	terminal:    bool,
}

Radix_Ptr :: struct {
	root:  ^Radix_Ptr_Node,
	nodes: [dynamic]^Radix_Ptr_Node,
}

@(private = "file")
radix_ptr_node :: proc(t: ^Radix_Ptr) -> ^Radix_Ptr_Node {
	n := new(Radix_Ptr_Node)
	n.children = make(map[string]^Radix_Ptr_Node)
	n.route = -1
	append(&t.nodes, n)
	return n
}

radix_ptr_build :: proc(t: ^Radix_Ptr, patterns: []string) -> bool {
	t.nodes = make([dynamic]^Radix_Ptr_Node, 0, len(patterns) * 2) or_else nil
	t.root = radix_ptr_node(t)
	for pattern, i in patterns {
		parts := split_path(pattern)
		if !parts.valid {
			return false
		}
		node := t.root
		for s in 0 ..< parts.count {
			seg := parts.seg[s]
			if len(seg) > 0 && seg[0] == ':' {
				if node.param_child == nil {
					node.param_child = radix_ptr_node(t)
				}
				node = node.param_child
				continue
			}
			child, found := node.children[seg]
			if !found {
				child = radix_ptr_node(t)
				node.children[seg] = child
			}
			node = child
		}
		node.terminal = true
		node.route = i
	}
	return true
}

radix_ptr_destroy :: proc(t: ^Radix_Ptr) {
	for n in t.nodes {
		delete(n.children)
		free(n)
	}
	delete(t.nodes)
	t.nodes = nil
	t.root = nil
}

// Static child before parametric child at EVERY level, which is what makes
// precedence structural in a tree — and is also where a tree can quietly get
// it wrong, since a static branch that dead-ends must fall back to the
// parametric one rather than declaring a miss.
@(private = "file")
radix_ptr_walk :: proc(
	node: ^Radix_Ptr_Node,
	p: ^Segments,
	depth: int,
	param: string,
) -> Match {
	if depth == p.count {
		if node.terminal {
			return Match{route = node.route, param = param, ok = true}
		}
		return MISS
	}
	seg := p.seg[depth]
	if child, found := node.children[seg]; found {
		if m := radix_ptr_walk(child, p, depth + 1, param); m.ok {
			return m
		}
	}
	if node.param_child != nil && len(seg) > 0 {
		if m := radix_ptr_walk(node.param_child, p, depth + 1, seg); m.ok {
			return m
		}
	}
	return MISS
}

radix_ptr_match :: proc(t: ^Radix_Ptr, path: string) -> Match {
	p := split_path(path)
	if !p.valid {
		return MISS
	}
	return radix_ptr_walk(t.root, &p, 0, "")
}

// ---------------------------------------------------------------------------
// CANDIDATE 6 — index-based radix. The same tree with nodes in a flat array.
//
// Identical logic, different memory layout: the whole point of measuring both
// is that the difference between them IS the layout, and this project chooses
// representations from its own numbers rather than from the general claim that
// indices beat pointers.
// ---------------------------------------------------------------------------

Radix_Idx_Node :: struct {
	children:    map[string]int,
	param_child: int,
	route:       int,
	terminal:    bool,
}

Radix_Idx :: struct {
	nodes: [dynamic]Radix_Idx_Node,
}

@(private = "file")
radix_idx_node :: proc(t: ^Radix_Idx) -> int {
	append(
		&t.nodes,
		Radix_Idx_Node{children = make(map[string]int), param_child = -1, route = -1},
	)
	return len(t.nodes) - 1
}

radix_idx_build :: proc(t: ^Radix_Idx, patterns: []string) -> bool {
	t.nodes = make([dynamic]Radix_Idx_Node, 0, len(patterns) * 2) or_else nil
	root := radix_idx_node(t)
	for pattern, i in patterns {
		parts := split_path(pattern)
		if !parts.valid {
			return false
		}
		cur := root
		for s in 0 ..< parts.count {
			seg := parts.seg[s]
			if len(seg) > 0 && seg[0] == ':' {
				if t.nodes[cur].param_child < 0 {
					// The append inside `radix_idx_node` may reallocate the
					// array, so the parent is re-indexed AFTER the child
					// exists. Holding a `^Node` across the append would be a
					// dangling pointer — the exact hazard an index-based
					// representation exists to avoid, and it still has to be
					// respected while BUILDING it.
					child := radix_idx_node(t)
					t.nodes[cur].param_child = child
				}
				cur = t.nodes[cur].param_child
				continue
			}
			child, found := t.nodes[cur].children[seg]
			if !found {
				child = radix_idx_node(t)
				t.nodes[cur].children[seg] = child
			}
			cur = child
		}
		t.nodes[cur].terminal = true
		t.nodes[cur].route = i
	}
	return true
}

radix_idx_destroy :: proc(t: ^Radix_Idx) {
	for &n in t.nodes {
		delete(n.children)
	}
	delete(t.nodes)
	t.nodes = nil
}

@(private = "file")
radix_idx_walk :: proc(t: ^Radix_Idx, node: int, p: ^Segments, depth: int, param: string) -> Match {
	if depth == p.count {
		if t.nodes[node].terminal {
			return Match{route = t.nodes[node].route, param = param, ok = true}
		}
		return MISS
	}
	seg := p.seg[depth]
	if child, found := t.nodes[node].children[seg]; found {
		if m := radix_idx_walk(t, child, p, depth + 1, param); m.ok {
			return m
		}
	}
	pc := t.nodes[node].param_child
	if pc >= 0 && len(seg) > 0 {
		if m := radix_idx_walk(t, pc, p, depth + 1, seg); m.ok {
			return m
		}
	}
	return MISS
}

radix_idx_match :: proc(t: ^Radix_Idx, path: string) -> Match {
	p := split_path(path)
	if !p.valid {
		return MISS
	}
	return radix_idx_walk(t, 0, &p, 0, "")
}

// ---------------------------------------------------------------------------
// CANDIDATE 7 — index radix whose nodes key children by a SORTED ARRAY plus
// binary search, rather than by a map.
//
// WP28 chose the shape of the TABLE and explicitly left the shape of a NODE
// unmeasured, which is a gap WP29 cannot inherit: the idiom guide warns against
// maps in hot dispatch, and a warning is not a number. The two node interiors
// have opposite expected answers — a map should win at fan-out 5,000 and lose
// at fan-out 10 — so this is measured on both the wide shapes and `Deep`.
//
// Everything except the node interior is identical to `radix_idx`, so the
// difference measured IS the node interior.
// ---------------------------------------------------------------------------

Radix_Arr_Node :: struct {
	// Parallel arrays, kept sorted by name at build time. Parallel rather than
	// an array of pairs so the binary search touches only the keys.
	child_names: [dynamic]string,
	child_nodes: [dynamic]int,
	param_child: int,
	route:       int,
	terminal:    bool,
}

Radix_Arr :: struct {
	nodes: [dynamic]Radix_Arr_Node,
}

@(private = "file")
radix_arr_node :: proc(t: ^Radix_Arr) -> int {
	append(
		&t.nodes,
		Radix_Arr_Node {
			child_names = make([dynamic]string),
			child_nodes = make([dynamic]int),
			param_child = -1,
			route = -1,
		},
	)
	return len(t.nodes) - 1
}

// Binary search over the sorted child names.
@(private = "file")
radix_arr_find :: proc(n: ^Radix_Arr_Node, seg: string) -> (node: int, found: bool) {
	lo := 0
	hi := len(n.child_names) - 1
	for lo <= hi {
		mid := (lo + hi) / 2
		switch {
		case n.child_names[mid] == seg:
			return n.child_nodes[mid], true
		case n.child_names[mid] < seg:
			lo = mid + 1
		case:
			hi = mid - 1
		}
	}
	return 0, false
}

radix_arr_build :: proc(t: ^Radix_Arr, patterns: []string) -> bool {
	t.nodes = make([dynamic]Radix_Arr_Node, 0, len(patterns) * 2) or_else nil
	root := radix_arr_node(t)
	for pattern, i in patterns {
		parts := split_path(pattern)
		if !parts.valid {
			return false
		}
		cur := root
		for s in 0 ..< parts.count {
			seg := parts.seg[s]
			if len(seg) > 0 && seg[0] == ':' {
				if t.nodes[cur].param_child < 0 {
					child := radix_arr_node(t)
					t.nodes[cur].param_child = child
				}
				cur = t.nodes[cur].param_child
				continue
			}
			child, found := radix_arr_find(&t.nodes[cur], seg)
			if !found {
				child = radix_arr_node(t)
				// Insert in sorted position, so lookup can binary search.
				// Registration may allocate and may be O(n); lookup may not.
				pos := 0
				for pos < len(t.nodes[cur].child_names) &&
				    t.nodes[cur].child_names[pos] < seg {
					pos += 1
				}
				inject_at(&t.nodes[cur].child_names, pos, seg)
				inject_at(&t.nodes[cur].child_nodes, pos, child)
			}
			cur = child
		}
		t.nodes[cur].terminal = true
		t.nodes[cur].route = i
	}
	return true
}

radix_arr_destroy :: proc(t: ^Radix_Arr) {
	for &n in t.nodes {
		delete(n.child_names)
		delete(n.child_nodes)
	}
	delete(t.nodes)
	t.nodes = nil
}

@(private = "file")
radix_arr_walk :: proc(t: ^Radix_Arr, node: int, p: ^Segments, depth: int, param: string) -> Match {
	if depth == p.count {
		if t.nodes[node].terminal {
			return Match{route = t.nodes[node].route, param = param, ok = true}
		}
		return MISS
	}
	seg := p.seg[depth]
	if child, found := radix_arr_find(&t.nodes[node], seg); found {
		if m := radix_arr_walk(t, child, p, depth + 1, param); m.ok {
			return m
		}
	}
	pc := t.nodes[node].param_child
	if pc >= 0 && len(seg) > 0 {
		if m := radix_arr_walk(t, pc, p, depth + 1, seg); m.ok {
			return m
		}
	}
	return MISS
}

radix_arr_match :: proc(t: ^Radix_Arr, path: string) -> Match {
	p := split_path(path)
	if !p.valid {
		return MISS
	}
	return radix_arr_walk(t, 0, &p, 0, "")
}

// ---------------------------------------------------------------------------
// Workload generation, shared so every candidate faces the identical table.
// ---------------------------------------------------------------------------

Shape :: enum u8 {
	All_Static,
	All_Param,
	Mixed,
	// Deep is the narrow tree real route tables actually look like.
	//
	// The other three shapes put every route under one prefix, so the node
	// above them has a fan-out equal to the whole table — 5,000 children at the
	// top cardinality. That is a stress case worth measuring and it is NOT what
	// an application registers. `Deep` spreads routes across digit segments, so
	// fan-out is at most 10 at every level and depth is 5.
	//
	// It exists because the node-interior question (a map, a sorted array, a
	// linear scan) has opposite answers at fan-out 5,000 and fan-out 10, and
	// measuring only the shape my own generator happened to produce would have
	// chosen the node by accident.
	Deep,
}

// generate_patterns builds `count` patterns and the paths that exercise them.
//
// The caller owns both, and both must be freed with `free_patterns`.
generate_patterns :: proc(
	count: int,
	shape: Shape,
) -> (
	patterns: [dynamic]string,
	paths: [dynamic]string,
) {
	patterns = make([dynamic]string, 0, count)
	paths = make([dynamic]string, 0, count)
	digits: [24]u8
	for i in 0 ..< count {
		parametric: bool
		switch shape {
		case .All_Static:
			parametric = false
		case .All_Param:
			parametric = true
		case .Mixed:
			parametric = i % 2 == 1
		case .Deep:
			parametric = false
		}
		if shape == .Deep {
			d1 := [1]u8{u8('0' + (i / 1000) % 10)}
			d2 := [1]u8{u8('0' + (i / 100) % 10)}
			d3 := [1]u8{u8('0' + (i / 10) % 10)}
			d4 := [1]u8{u8('0' + i % 10)}
			seg := strings.concatenate(
				{"/d/", string(d1[:]), "/", string(d2[:]), "/", string(d3[:]), "/", string(d4[:])},
			)
			append(&patterns, seg)
			append(&paths, strings.clone(seg))
			continue
		}
		if parametric {
			append(&patterns, strings.concatenate({"/bench/p", itoa(&digits, i), "/:id"}))
			append(&paths, strings.concatenate({"/bench/p", itoa(&digits, i), "/42"}))
		} else {
			append(&patterns, strings.concatenate({"/bench/s", itoa(&digits, i)}))
			append(&paths, strings.concatenate({"/bench/s", itoa(&digits, i)}))
		}
	}
	return
}

free_patterns :: proc(patterns: ^[dynamic]string, paths: ^[dynamic]string) {
	for s in patterns^ {
		delete(s)
	}
	delete(patterns^)
	for s in paths^ {
		delete(s)
	}
	delete(paths^)
	patterns^ = nil
	paths^ = nil
}

// A tiny base-10 formatter, so pattern generation does not drag `core:fmt` and
// its allocations into a file the shootout compiles.
//
// THE BUFFER IS THE CALLER'S, and that is not a style preference. A first
// version of this used a package-level `[24]u8` and passed every test in
// isolation while failing inside `odin test` — which runs suites on seven
// threads, so two tests calling `generate_patterns` concurrently corrupted each
// other's digits and produced patterns that matched nothing. The symptom was
// six "missing" routes and a benchmark harness accusing its own candidates.
//
// A shared mutable global in a test-support package is a data race waiting for
// a parallel runner, and this project has a parallel runner.
@(private = "file")
itoa :: proc(buf: ^[24]u8, v: int) -> string {
	if v == 0 {
		buf[0] = '0'
		return string(buf[:1])
	}
	n := v
	i := len(buf)
	for n > 0 {
		i -= 1
		buf[i] = u8('0' + n % 10)
		n /= 10
	}
	return string(buf[i:])
}
