# AntCrate — User Duties

Actions only the human can perform. Agents append via `antcrate --duty`;
items flip to done via `antcrate --duty-done <n>` — never deleted.

- [x] 2026-06-11 — install smoke — flip me (done 2026-06-11)
- [x] 2026-06-11 — Decide gh public-repo policy: which future repos default public vs stay private (current rule: everything private unless --public); affects --gh-init and parked gh-publish/mirror proposals (done 2026-06-11)
- [x] 2026-06-11 — Set a key-rotation cadence for GitHub tokens / gh auth and any service credentials antcrate touches (no rotation schedule exists today) (done 2026-06-11)
- [x] 2026-06-12 — land the least-cost implementation plan (TH command-duty): from ~/projects/antcrate: cp .claude/worktrees/least-cost-spec/docs/plans/2026-06-11-least-cost-allocation-and-skill-scoping.md docs/plans/ then ANTCRATE_COMMIT_PREAPPROVED=1 antcrate --commit antcrate -m 'docs(plans): least-cost implementation plan' -- docs/plans/2026-06-11-least-cost-allocation-and-skill-scoping.md then antcrate --pp antcrate -y. OR just /clear and the next session does it (steps in state.md). (done 2026-06-12)
- [ ] 2026-06-12 — [command] Enable the Pipe daemon persistently: systemctl --user enable --now antcrated  (daemon verified working 2026-06-12 via direct-run smoke — tree.mmd auto-regen fired on friendly_cars touch; enable/start is control-plane, gateway-blocked for agents)
