package main

// STORAGE — where the thing LIVES.
//
// In-memory here so the example runs with nothing installed. Swapping this file
// for one over `crystals:db/postgres` changes nothing above it: the service
// calls these four procedures and never learns what is behind them.

Store :: struct {
	links: map[string]Link,
}

store_open :: proc() -> Store {
	return Store{links = make(map[string]Link)}
}

store_close :: proc(s: ^Store) {
	delete(s.links)
}

store_put :: proc(s: ^Store, l: Link) {
	s.links[l.slug] = l
}

store_get :: proc(s: ^Store, slug: string) -> (Link, bool) {
	l, found := s.links[slug]
	return l, found
}

store_bump :: proc(s: ^Store, slug: string) {
	if l, found := s.links[slug]; found {
		l.hits += 1
		s.links[slug] = l
	}
}
