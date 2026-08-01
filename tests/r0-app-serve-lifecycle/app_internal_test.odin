// Internal R0 control for the one-active-serve-per-App claim.
// build/check_wp123_controls.sh copies this beside the real web sources.
package web

import "core:sync"
import "core:testing"
import "core:thread"

R0_CLAIM_THREADS :: 16

R0_Claim_Work :: struct {
	app:       ^App,
	start:     ^sync.Sema,
	attempted: ^sync.Sema,
	release:   ^sync.Sema,
	winners:   ^int,
}

r0_claim_worker :: proc(work: ^R0_Claim_Work) {
	sync.sema_wait(work.start)
	won := app_claim_serve(work.app)
	if won {
		_ = sync.atomic_add(work.winners, 1)
	}
	sync.sema_post(work.attempted)
	if won {
		sync.sema_wait(work.release)
		app_release_serve(work.app)
	}
}

@(test)
r0_only_one_concurrent_serve_claims_an_app :: proc(t: ^testing.T) {
	a := app()
	defer destroy(&a)

	start, attempted, release: sync.Sema
	winners: int
	works: [R0_CLAIM_THREADS]R0_Claim_Work
	threads: [R0_CLAIM_THREADS]^thread.Thread
	for i in 0 ..< R0_CLAIM_THREADS {
		works[i] = R0_Claim_Work {
			app = &a,
			start = &start,
			attempted = &attempted,
			release = &release,
			winners = &winners,
		}
		threads[i] = thread.create_and_start_with_poly_data(&works[i], r0_claim_worker)
	}

	sync.sema_post(&start, R0_CLAIM_THREADS)
	for _ in 0 ..< R0_CLAIM_THREADS {
		sync.sema_wait(&attempted)
	}
	testing.expectf(
		t,
		sync.atomic_load(&winners) == 1,
		"SERVE-CLAIM-MULTIPLE-WINNERS: %d concurrent callers claimed one App",
		sync.atomic_load(&winners),
	)
	sync.sema_post(&release)
	for worker in threads {
		thread.join(worker)
		thread.destroy(worker)
	}

	// A completed non-draining attempt releases the claim for a retry.
	testing.expect(t, app_claim_serve(&a), "a released non-draining App may retry serve")
	app_release_serve(&a)

	// Draining is monotonic: no Draining -> Serving transition exists.
	stop(&a)
	testing.expect(t, !app_claim_serve(&a), "a draining App must refuse a new serve")
}
