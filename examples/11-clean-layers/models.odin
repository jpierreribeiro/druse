package main

// DOMAIN — what the thing IS.
//
// No HTTP, no JSON, no storage. This file would be identical if the service
// were a CLI. That is the test for whether something belongs here: if it
// mentions a status code or a column name, it belongs in another layer.

Link :: struct {
	slug:   string,
	target: string,
	hits:   int,
}

// The domain's own rules, expressed as a closed result rather than a bool, so a
// caller must say what it does about each case. `Invalid_Slug` is the zero
// value: an unassigned result refuses.
Link_Result :: enum {
	Invalid_Slug,
	Ok,
	Invalid_Target,
	Slug_Taken,
	Not_Found,
}

MAX_SLUG_BYTES :: 32
MAX_TARGET_BYTES :: 2048

slug_ok :: proc(s: string) -> bool {
	if len(s) == 0 || len(s) > MAX_SLUG_BYTES {
		return false
	}
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		ok := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-'
		if !ok {
			return false
		}
	}
	return true
}

target_ok :: proc(s: string) -> bool {
	return len(s) > 0 && len(s) <= MAX_TARGET_BYTES
}
