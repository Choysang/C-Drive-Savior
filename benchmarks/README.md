# Scanner benchmarks

Run the fixed repository fixture three times:

```powershell
pwsh -NoProfile -File benchmarks/run-scanners.ps1 -ScanRoot tests/fixtures/runtime -Runs 3
```

Run one real read-only C-drive comparison:

```powershell
pwsh -NoProfile -File benchmarks/run-scanners.ps1 -ScanRoot C:\ -Runs 1
```

The runner creates a detached temporary worktree at the pinned baseline commit, runs baseline and current PowerShell/Python scanners sequentially, then removes only that worktree. `results.json` records raw duration, peak working set, environment, dataset size, denied paths, completion state, and contract status. `summary.md` reports medians.

For a repository fixture, the legacy PowerShell adapter disables only its hidden-system-consumer probe because that probe is hard-coded to the live Windows installation and cannot be redirected to the fixture. Its directory traversal and report generation remain unchanged. Full-drive mode runs the legacy script unchanged. The Python adapter calls each snapshot's core traversal directly so both versions receive exactly the requested root.

Results are machine-specific. Do not add a speed claim to the project README until the old and new raw artifacts from the same machine and dataset have been saved and reviewed. Benchmark output belongs in `benchmark-results/` and is intentionally ignored by Git.
