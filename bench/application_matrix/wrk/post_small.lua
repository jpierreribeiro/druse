wrk.method = "POST"
wrk.path = "/json/echo"
wrk.headers["Content-Type"] = "application/json"
wrk.body = '{"id":42,"name":"Ada","email":"ada@example.com","active":true}'
