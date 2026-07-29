package main

import "core:fmt"
import "core:time"
import lab "druse:tests/support/blocking_lab"

run_arm :: proc(port, lanes, blockers: int) -> (live: bool, health, baseline: time.Duration) {
	s: lab.Server
	if !lab.Start(&s, port, lanes) {
		fmt.eprintf("arm port=%d failed to start\n", port)
		return false, 0, 0
	}

	// Call contains thread/semaphore state. Keep it at a stable address exactly
	// like the conformance test instead of making allocator behaviour another
	// experimental variable.
	call_storage: [4]lab.Call
	calls := call_storage[:blockers]
	health_call: lab.Call
	defer {
		lab.Stop(&s)
		for &call in calls {
			lab.Join_Call(&call)
		}
		lab.Join_Call(&health_call)
	}
	baseline_status: int
	baseline_ok: bool
	baseline_status, baseline, baseline_ok = lab.Request(port, "/health")
	_ = baseline_status
	if !baseline_ok || baseline >= lab.Baseline_Ceiling {
		fmt.eprintf("arm port=%d has invalid baseline=%v\n", port, baseline)
		return false, 0, baseline
	}
	for &call in calls {
		lab.Start_Call(&call, port, "/block")
		if !lab.Wait_Entered(&s) {
			fmt.eprintf("arm port=%d failed to occupy blocker lane\n", port)
			return false, 0, baseline
		}
	}
	lab.Start_Call(&health_call, port, "/health")
	live = lab.Wait_Call(&health_call, lab.Observation_Window)
	lab.Release(&s, blockers)
	for &call in calls {
		_ = lab.Wait_Call(&call, 2 * time.Second)
	}
	if !live {
		_ = lab.Wait_Call(&health_call, 2 * time.Second)
	}
	health = health_call.elapsed
	return
}

main :: proc() {
	multi_live, multi_health, multi_base := run_arm(50981, 4, 3)
	full_live, full_health, full_base := run_arm(50982, 4, 4)
	one_live, one_health, one_base := run_arm(50980, 1, 1)

	fmt.printf("one-lane, one blocker      health_before_release=%v observed=%v baseline=%v\n", one_live, one_health, one_base)
	fmt.printf("four lanes, three blockers health_before_release=%v observed=%v baseline=%v\n", multi_live, multi_health, multi_base)
	fmt.printf("four lanes, four blockers  health_before_release=%v observed=%v baseline=%v\n", full_live, full_health, full_base)
	fmt.printf("record lower bounds         lane=%dB connection=%dB\n", lab.Lane_Record_Bytes, lab.Connection_Record_Bytes)
	fmt.println("job-pool arm                 not viable with synchronous Dispatch_Proc/Outbound lifetime")
}
