package main

// SERVICE — what the thing DOES.
//
// Every rule the application has lives here, and nothing else does. It takes a
// `^Store` and plain values; it returns a domain result. It cannot answer a
// request because it cannot see one, which is exactly why it is testable
// without a socket.

create_link :: proc(s: ^Store, slug: string, target: string) -> (Link, Link_Result) {
	if !slug_ok(slug) {
		return Link{}, .Invalid_Slug
	}
	if !target_ok(target) {
		return Link{}, .Invalid_Target
	}
	if _, taken := store_get(s, slug); taken {
		return Link{}, .Slug_Taken
	}

	l := Link{slug = slug, target = target, hits = 0}
	store_put(s, l)
	return l, .Ok
}

visit_link :: proc(s: ^Store, slug: string) -> (Link, Link_Result) {
	l, found := store_get(s, slug)
	if !found {
		return Link{}, .Not_Found
	}
	store_bump(s, slug)
	l.hits += 1
	return l, .Ok
}

read_link :: proc(s: ^Store, slug: string) -> (Link, Link_Result) {
	l, found := store_get(s, slug)
	if !found {
		return Link{}, .Not_Found
	}
	return l, .Ok
}
