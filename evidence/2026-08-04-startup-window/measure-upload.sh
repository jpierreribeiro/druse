SRV="$1"; PORT="$2"; N="$3"; DIR="$4"
mkdir -p "$DIR"
for i in $(seq 1 $N); do
  T0=$(date +%s%N)
  taskset -c 0,1 "$SRV" "$PORT" "$DIR" >/dev/null 2>&1 &
  PID=$!
  READY=0
  for _ in $(seq 1 4000); do
    if timeout 1 bash -c "cat < /dev/null > /dev/tcp/127.0.0.1/$PORT" 2>/dev/null; then READY=1; break; fi
    sleep 0.002
  done
  T1=$(date +%s%N)
  kill $PID 2>/dev/null; wait $PID 2>/dev/null
  if [ $READY = 1 ]; then echo $(( (T1-T0)/1000000 )); else echo TIMEOUT; fi
  sleep 0.3
done
