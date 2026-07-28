package main

// DTO — what crosses the WIRE.
//
// Separate from the domain on purpose. `Link` has `hits`, which a client does
// not set; `Create_Link` has no `hits` at all, so a client cannot invent one.
// One struct for both is how a caller assigns its own primary key.

Create_Link :: struct {
	slug:   string `json:"slug"`,
	target: string `json:"target"`,
}

Link_View :: struct {
	slug:   string `json:"slug"`,
	target: string `json:"target"`,
	hits:   int    `json:"hits"`,
}

Error_View :: struct {
	code:    string `json:"code"`,
	message: string `json:"message"`,
}

// The one place the domain becomes the wire. A field added to `Link` does not
// reach a client until somebody edits this procedure.
view_of :: proc(l: Link) -> Link_View {
	return Link_View{slug = l.slug, target = l.target, hits = l.hits}
}
