local items = {}
for i = 1, 64 do
  items[#items + 1] = string.format(
    '{"id":%d,"name":"item-%02d-abcdefghijklmnop","score":%d.5,"active":true}',
    i,
    i,
    i
  )
end

local statuses = {}

wrk.method = "POST"
wrk.path = os.getenv("DRUSE_BENCH_PATH") or "/json/medium"
wrk.headers["Content-Type"] = "application/json"
wrk.body = '{"request_id":"req-0123456789abcdef","items":['
  .. table.concat(items, ",")
  .. '],"tags":["alpha","beta","gamma","delta","epsilon","zeta"]}'

response = function(status)
  statuses[status] = (statuses[status] or 0) + 1
  if status ~= 200 and statuses[status] <= 3 then
    print(string.format("observed_status=%d", status))
  end
end

done = function()
  for status, count in pairs(statuses) do
    io.write(string.format("status_%d=%d\n", status, count))
  end
end
