# Reference

Every symbol in the public ledger, with its exact signature.

This is the lookup. For how to *use* something, the guide is
[`../guide/README.md`](../guide/README.md).

The ledger is enforced in both directions: a missing symbol and an extra
symbol are equally a build failure. So this page is the whole surface —
if something is not here, it does not exist.

| Page | |
|---|---|
| [Application](application.md) | Creating, configuring, serving and stopping. |
| [Routing](routing.md) | Registering routes, grouping them, and middleware. |
| [Request](request.md) | Reading input. Every string here is a view into the request buffer. |
| [Response](response.md) | Sending output. One response per request. |
| [Streaming](streaming.md) | A response the handler does not buffer whole. |
| [Uploads](uploads.md) | Bodies spooled to disk instead of held in memory. |
| [Browser and proxy](browser.md) | CORS, static files, security headers, and the real client address. |
| [Observability](observability.md) | What failed, how often, and what the server is doing. |
| [Testing](testing.md) | The separate two-symbol ledger. It cannot grow by borrowing the application budget. |

**82 symbols**: 61 procedures, 20 types, 1 constant. The application ledger holds 80 and the test-support ledger 2.
