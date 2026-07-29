local items = {}
for i = 1, 64 do
  items[#items + 1] = string.format(
    '{"id":%d,"name":"item-%02d-abcdefghijklmnop","score":%d.5,"active":true}',
    i,
    i,
    i
  )
end

wrk.method = "POST"
wrk.path = os.getenv("DRUSE_BENCH_PATH") or "/json/medium"
wrk.headers["Content-Type"] = "application/json"
wrk.body = '{"request_id":"req-0123456789abcdef","items":['
  .. table.concat(items, ",")
  .. '],"tags":["alpha","beta","gamma","delta","epsilon","zeta"]}'
