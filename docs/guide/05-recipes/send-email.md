# Send an email

Package `crystals:mail`, with `mail_http` for a real provider and
`mail_memory` for tests.

## Build the message

```odin
	msg := mail.Message{
		from    = mail.Address{...},
		subject = "Welcome",
		...
	}
	if err := mail.validate(msg); err != .None {
		return
	}
	r := mail.send(sender, msg)
```

`mail.validate` checks the message before any network call. Call it — a
malformed address costs you a round trip otherwise.

`MAX_RECIPIENTS`, `MAX_SUBJECT_BYTES`, `MAX_BODY_BYTES` and
`MAX_ADDRESS_BYTES` bound it. Over any of them the message is refused, not
truncated.

## Give it the application's HTTP client

```odin
	sender := mail_http.open(&state.http, cfg)
```

**`mail_http.open` takes your `http_client` rather than building its own.**
That is the important line on this page.

One client means the pool bound, the timeouts and the TLS policy are **one
decision in one place**. A package that opened its own would give you a second
set of timeouts you did not choose and cannot see.

This is the pattern for every Crystal that talks outward. Look for it.

## Sending is slow — do it in a job

An SMTP or API call takes as long as somebody else's server takes. Doing it
inside a handler makes your response time theirs.

Enqueue a job instead, and let a worker send it. See
[`run-background-jobs.md`](run-background-jobs.md).

## Retries need an idempotency key

`Message` carries one, bounded by `MAX_IDEMPOTENCY_KEY_BYTES`. Set it, and a
retried job does not send a second copy.

Without it, at-least-once delivery of the job becomes at-least-once delivery of
the **email**, which the recipient notices.

## Testing

`mail_memory` implements the same `Sender` and records what was sent. No
network, no provider account, and your test asserts on the message.
