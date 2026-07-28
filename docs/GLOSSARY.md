# Glossary

The approved terms. Each has one meaning and one part of speech. `STYLE.md` §2
requires you to use these and no synonym.

Add a term here before you use it in a page.

## Product

| Term | Part of speech | Meaning |
|---|---|---|
| **Druse** | proper noun | The core framework. Repository `druse`, collection `druse:`. |
| **Crystals** | proper noun | The extension library. Repository `druse-crystals`, collection `crystals:`. |
| **Crystal** | noun | One package in Crystals. |

`Druse Crystals` is the display name of the `druse-crystals` repository. Do not
use it in body text.

Do not write `the Druse framework`, `Druse core`, `the Crystals library` or
`the ecosystem`. `Druse` and `Crystals` already carry those meanings.

**Forbidden:** `uruquim`, `uruquim-crystals`, `uruquim-odin`, and every case
variant. These are the former names. A build check refuses them
(`documentation-program.md` §8).

## Structure

| Term | Part of speech | Meaning |
|---|---|---|
| **application** | noun | The program you write. It owns composition and every long-lived value. |
| **composition root** | noun | The one procedure, usually `main`, where the application creates services and mounts routers. |
| **handler** | noun | A procedure that answers one request. Signature `proc(ctx: ^web.Context)`. |
| **middleware** | noun | A procedure that runs around a handler. Registered with `web.use`. |
| **router** | noun | A detached `web.Router`. A Crystal returns one; the application mounts it. |
| **mount** | verb | Attach a router to an application under a prefix. `web.mount` copies the router. |
| **extractor** | noun | A procedure that reads one value from a request. A fallible extractor answers `400` itself. |
| **service** | noun | An app-lived resource the application owns. A pool is a service. |
| **store** | noun | A contract struct of procedures over a backend. `session.Store` is one. |

## Lifetime

These five terms are the whole of `guide/04-rules/ownership-and-lifetime.md`.
Use them exactly.

| Term | Part of speech | Meaning |
|---|---|---|
| **own** | verb | To be responsible for the release of a value. Exactly one holder owns a value. |
| **view** | noun | A string or slice that points into memory some other value owns. A view has no independent life. |
| **borrow** | verb | To take a view. The borrower must not outlive the owner. |
| **clone** | verb | To copy bytes into an allocator the caller names, so the copy outlives the source. |
| **release** | verb | To return a value to the service that lent it. `release` returns a connection to a pool. |

Do not write `free`, `dispose`, `reclaim`, `hand back` or `give up`. Write
`release` for a lent resource and `destroy` for a value the application owns.

| Term | Part of speech | Meaning |
|---|---|---|
| **open** / **close** | verb | Acquire and release something a package owns. The pair is load-bearing across Crystals. |
| **destroy** | verb | Free a value that accumulated memory. Not a resource. `validate.destroy` is the model. |
| **request lifetime** | noun | The period during which a request's memory stays valid. It ends when the handler returns. |

## Results

| Term | Part of speech | Meaning |
|---|---|---|
| **result** | noun | A closed enum reporting the outcome of one operation. |
| **fail closed** | verb phrase | To deny, refuse or report failure when the outcome is unknown or unassigned. |
| **zero value** | noun | The value a variable holds when nothing assigned it. In a result enum it is always the safe one. |
| **refuse** | verb | To decline an operation for a stated reason. A checksum mismatch refuses a migration. |
| **reject** | verb | To decline a presented credential. Reserved for verification. |

`refuse` and `reject` are not synonyms. A package refuses work. A verifier
rejects a token.

## Data

| Term | Part of speech | Meaning |
|---|---|---|
| **subject** | noun | The identity a credential belongs to, as a bounded inline value in a record. |
| **principal** | noun | The authenticated identity a policy decides about. `authorization.Principal`. |
| **decision** | noun | The result of a policy. `authorization.Decision`. Carries `allowed` and a reason. |
| **cursor** | noun | The position of a `Rows` value in its result set. |
| **migration** | noun | One ordered, immutable schema change with a stable id. |
| **pool** | noun | A bounded set of database connections the application owns. |

`subject` names one thing: the bounded inline identity in a record. Do not use
it for a principal, for a decision's target, or for a user record.
