# C Drive Savior Dual-Scanner Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the current v2 prototype into a session-bound, contract-tested Windows cleanup skill whose PowerShell and Python scanners agree semantically and whose destructive scripts reject unapproved or unsafe operations.

**Architecture:** Keep PowerShell as the zero-dependency default and Python as an equivalent optional scanner. Both emit the same v2 JSON contract and use one classification catalog and one static HTML template; PowerShell cleanup and migration scripts consume a user-approved session file and enforce path, service, and copy-integrity rules themselves.

**Tech Stack:** Windows PowerShell 5.1, PowerShell 7, Python 3.9-3.13 standard library, Pester 5 for development tests, `jsonschema` for development/CI contract validation, Robocopy, static HTML/CSS/JavaScript, GitHub Actions.

---

## Scope And File Map

Create:

- `config/classification.json` - shared GREEN/YELLOW/RED/MOVE rules and the 27 cleanup item definitions.
- `schemas/session-v2.schema.json` - allowed session states and artifact paths.
- `schemas/scan-v2.schema.json` - common scanner output contract.
- `schemas/decisions-v2.schema.json` - user-approved item IDs and protected paths.
- `schemas/action-v2.schema.json` - one structured clean/migrate action record.
- `modules/CDriveSavior.Core.psm1` - path, session, schema, error, service, and log helpers.
- `native/FileIdentity.cs` - Windows file identity and allocated-size helper used by PowerShell.
- `scripts/decide.ps1` - validates and records the one-round user decision.
- `assets/report_template.html` - shared scan/final-report renderer with no deletion API.
- `tests/powershell/Core.Tests.ps1`
- `tests/powershell/Decision.Tests.ps1`
- `tests/powershell/Scan.Tests.ps1`
- `tests/powershell/Clean.Tests.ps1`
- `tests/powershell/Migrate.Tests.ps1`
- `tests/powershell/Report.Tests.ps1`
- `tests/python/test_schema_files.py`
- `tests/python/test_classification.py`
- `tests/python/test_documentation.py`
- `tests/python/test_scanner.py`
- `tests/python/test_scanner_contract.py`
- `tests/helpers/New-TestFixture.ps1`
- `tests/fixtures/expected-scan.json`
- `tests/run-all.ps1`
- `benchmarks/run-scanners.ps1`
- `benchmarks/README.md`
- `requirements-dev.txt`
- `.github/workflows/test.yml`
- `.github/PULL_REQUEST_TEMPLATE.md`

Modify:

- `scripts/scan.ps1` - stream one tree once and emit `scan-v2`.
- `scripts/c_drive_panel.py` - equivalent streaming Python scanner.
- `scripts/clean.ps1` - require approved session and enforce catalog path boundaries.
- `scripts/migrate.ps1` - split stage/finalize and verify before deleting source.
- `scripts/report.ps1` - report one session only with raw-byte accounting.
- `SKILL.md` - state-machine orchestration and bundled-script-only execution rule.
- `README.md` - truthful compatibility, usage, benchmark, and safety claims.
- `references/decision-model.md` - point to shared catalog and explain size accuracy.
- `references/pitfalls.md` - add the newly discovered v2 failures and mitigations.
- `references/relocation-guide.md` - document staged migration and finalize.
- `evals/evals.json` - add machine-gradeable safety assertions and six adversarial prompts.
- `.gitignore` - ignore generated sessions, reports, benchmark output, and Python cache.

Do not add a database, web deletion server, background service, uninstall automation, or a third scanner implementation.

## Agent Allocation During Execution

- Use `gpt-5.6-luna` for bounded, low-risk work such as schema fixtures, documentation assertions, CI YAML, and benchmark formatting.
- Keep path canonicalization, cleaner execution, migration finalize, session authorization, and final integration review on the parent/frontier model.
- Give parallel workers disjoint file ownership and require them to preserve concurrent changes.
- After each worker task, perform both a specification review and a code-quality/safety review before accepting the change.

## Milestone 1: Contracts And Session Safety

### Task 1: Add Versioned JSON Contracts

**Files:**

- Create: `requirements-dev.txt`
- Create: `schemas/session-v2.schema.json`
- Create: `schemas/scan-v2.schema.json`
- Create: `schemas/decisions-v2.schema.json`
- Create: `schemas/action-v2.schema.json`
- Create: `tests/python/test_schema_files.py`

- [ ] **Step 1: Write the failing schema-presence test and its development dependency**

Create `tests/python/test_schema_files.py` with these tests:

```python
import json
import unittest
from pathlib import Path

from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parents[2]
SCHEMAS = ROOT / "schemas"


class SchemaFileTests(unittest.TestCase):
    def load_schema(self, name: str) -> dict:
        path = SCHEMAS / name
        self.assertTrue(path.is_file(), f"missing schema: {path}")
        schema = json.loads(path.read_text(encoding="utf-8"))
        Draft202012Validator.check_schema(schema)
        return schema

    def test_all_v2_schemas_exist_and_are_valid(self) -> None:
        for name in (
            "session-v2.schema.json",
            "scan-v2.schema.json",
            "decisions-v2.schema.json",
            "action-v2.schema.json",
        ):
            with self.subTest(name=name):
                self.load_schema(name)

    def test_action_status_is_closed_enum(self) -> None:
        schema = self.load_schema("action-v2.schema.json")
        status = schema["properties"]["status"]["enum"]
        self.assertEqual(
            status,
            ["planned", "completed", "partial", "failed", "skipped", "not-found"],
        )


if __name__ == "__main__":
    unittest.main()
```

Create `requirements-dev.txt` before running the test:

```text
jsonschema==4.23.0
```

- [ ] **Step 2: Run the test and confirm the red state**

Run:

```powershell
python -m pip install -r requirements-dev.txt
python -m unittest tests.python.test_schema_files -v
```

Expected: dependency installation succeeds, then tests FAIL because the four schema files do not exist.

- [ ] **Step 3: Add the schema contracts**

All four schemas use draft 2020-12, set `additionalProperties` to `false`, and require `schema_version: 2`.

Use these exact required fields:

| Schema | Required fields |
|---|---|
| session | `schema_version`, `session_id`, `state`, `created_at`, `updated_at`, `root`, `artifacts` |
| scan | `schema_version`, `session_id`, `generated_at`, `source_engine`, `engine_version`, `scan_complete`, `scan_seconds`, `drives`, `rows`, `hidden`, `denied_paths`, `skipped_reparse_points`, `system_and_other_bytes` |
| decisions | `schema_version`, `session_id`, `approved_at`, `approved_clean_ids`, `approved_move_ids`, `protected_paths` |
| action | `schema_version`, `session_id`, `tool`, `item_id`, `action`, `status`, `started_at`, `finished_at`, `before_bytes`, `after_bytes`, `freed_bytes`, `source`, `destination`, `error_code`, `error_message`, `undo` |

Use these exact nested objects:

| Object | Required fields |
|---|---|
| `session.artifacts` | `scan`, `decisions`, `actions`, `panel`, `report`, each a path string relative to the session root |
| `scan.drives[]` | `letter`, `filesystem`, `total_bytes`, `used_bytes`, `free_bytes` |
| `scan.rows[]` | `id`, `parent_id`, `path`, `depth`, `logical_bytes`, `unique_bytes`, `exclusive_bytes`, `size_accuracy`, `tier`, `note` |
| `scan.hidden[]` | `id`, `label`, `bytes`, `size_accuracy`, `requires_admin`, `overlaps_visible_scan`, `note`, `error` |
| `scan.denied_paths[]` | `path`, `error_code`, `error_message` |
| `scan.skipped_reparse_points[]` | `path`, `kind`, `target` |
| `action.undo` | `kind`, `steps`; each step requires `action`, `source`, `destination`, and `path`, with unused location fields set to `null` |

Decision arrays contain unique strings. `approved_clean_ids` may reference only GREEN scan rows and `approved_move_ids` only MOVE rows; JSON Schema validates shape while `decide.ps1` validates that cross-file rule.

Use these closed enums:

```json
{
  "session_state": ["scanned", "awaiting-decision", "approved", "executing", "reported", "failed"],
  "tier": ["GREEN", "YELLOW", "RED", "MOVE"],
  "size_accuracy": ["allocated", "file-id-deduplicated", "logical"],
  "action_status": ["planned", "completed", "partial", "failed", "skipped", "not-found"]
}
```

Define `bytes` fields as integers with `minimum: 0`; nullable measurements use `type: ["integer", "null"]`. A scan row requires `id`, `parent_id`, `path`, `depth`, `logical_bytes`, `unique_bytes`, `exclusive_bytes`, `size_accuracy`, `tier`, and `note`.

- [ ] **Step 4: Run schema tests and validate JSON syntax**

Run:

```powershell
python -m unittest tests.python.test_schema_files -v
Get-ChildItem schemas\*.json | ForEach-Object { Get-Content -Raw $_ | ConvertFrom-Json | Out-Null }
```

Expected: two Python tests pass; PowerShell exits 0 with no JSON parse errors.

- [ ] **Step 5: Commit the contracts**

```powershell
git add requirements-dev.txt schemas tests/python/test_schema_files.py
git commit -m "test: define v2 artifact contracts"
```

### Task 2: Centralize Classification And Cleanup Catalog Data

**Files:**

- Create: `config/classification.json`
- Create: `tests/python/test_classification.py`
- Modify: `scripts/clean.ps1`
- Modify: `scripts/scan.ps1`
- Modify: `scripts/c_drive_panel.py`

- [ ] **Step 1: Write the failing catalog integrity tests**

Create `tests/python/test_classification.py`:

```python
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class ClassificationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.data = json.loads(
            (ROOT / "config" / "classification.json").read_text(encoding="utf-8")
        )

    def test_cleanup_ids_are_unique_and_complete(self) -> None:
        ids = [item["id"] for item in self.data["cleanup_items"]]
        self.assertEqual(len(ids), 27)
        self.assertEqual(len(ids), len(set(ids)))

    def test_no_cleanup_target_is_a_raw_absolute_path(self) -> None:
        for item in self.data["cleanup_items"]:
            for resolver in item["resolvers"]:
                self.assertNotRegex(resolver, r"^[A-Za-z]:\\")

    def test_protected_prefixes_include_windows_core(self) -> None:
        prefixes = {value.casefold() for value in self.data["protected_prefixes"]}
        self.assertIn("windows/system32", prefixes)
        self.assertIn("windows/winsxs", prefixes)
        self.assertIn("windows/installer", prefixes)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the catalog test and confirm it fails**

Run:

```powershell
python -m unittest tests.python.test_classification -v
```

Expected: FAIL with `FileNotFoundError` for `config/classification.json`.

- [ ] **Step 3: Create the shared catalog**

The 27 cleanup IDs must remain exactly:

```text
temp-user, crashdumps, dxcache, thumbcache, chrome-cache, edge-cache,
firefox-cache, npm, pnpm, yarn, pip, uv, playwright, puppeteer,
node-gyp, go-build, nuget, gradle, squirrel, wer-user, temp-windows,
wu-cache, delivery-opt, minidump, memdump, wer-system, recyclebin
```

Each cleanup item has this shape:

```json
{
  "id": "chrome-cache",
  "tier": "GREEN",
  "admin": false,
  "label": "Chrome caches",
  "owner_processes": ["chrome"],
  "resolvers": [
    "localappdata:Google/Chrome/User Data/*/Cache",
    "localappdata:Google/Chrome/User Data/*/Code Cache",
    "localappdata:Google/Chrome/User Data/*/GPUCache",
    "localappdata:Google/Chrome/User Data/optimization_guide_model_store",
    "localappdata:Google/Chrome/User Data/*/Service Worker/CacheStorage"
  ]
}
```

Allowed resolver roots are only `temp`, `localappdata`, `profile`, `systemroot`, `programdata`, and the special resolvers `delivery-optimization` and `recycle-bin`. Convert every current `$Catalog.paths` value to one of these resolver forms. Put RED path rules in `protected_prefixes`, GREEN/YELLOW/MOVE name rules in separate arrays, and keep the WeChat-specific consequence in `special_cases`.

- [ ] **Step 4: Make all three consumers load the catalog**

PowerShell resolves the catalog relative to `$PSScriptRoot`:

```powershell
$CatalogPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'config\classification.json'
$Classification = Get-Content -Raw -LiteralPath $CatalogPath | ConvertFrom-Json
```

Python resolves it relative to `__file__`:

```python
ROOT = Path(__file__).resolve().parents[1]
CLASSIFICATION = json.loads(
    (ROOT / "config" / "classification.json").read_text(encoding="utf-8")
)
```

Remove the duplicated `$GreenNames`, `$YellowNames`, `$MoveNames`, `$RedPrefixes`, `GREEN_NAMES`, `YELLOW_NAMES`, `MOVE_NAMES`, and `RED_PREFIXES` definitions only after the consumers use the shared data.

- [ ] **Step 5: Run catalog and syntax tests**

Run:

```powershell
python -m unittest tests.python.test_classification -v
powershell -NoProfile -Command "$e=$null;$t=$null;[Management.Automation.Language.Parser]::ParseFile('scripts\clean.ps1',[ref]$t,[ref]$e)|Out-Null;if($e.Count){$e;exit 1}"
python -m py_compile scripts\c_drive_panel.py
```

Expected: three classification tests pass; both parsers exit 0.

- [ ] **Step 6: Commit the catalog**

```powershell
git add config scripts/clean.ps1 scripts/scan.ps1 scripts/c_drive_panel.py tests/python/test_classification.py
git commit -m "refactor: share cleanup classification catalog"
```

### Task 3: Add Core Path And Session Guards

**Files:**

- Create: `modules/CDriveSavior.Core.psm1`
- Create: `tests/powershell/Core.Tests.ps1`
- Modify: `.gitignore`

- [ ] **Step 1: Write failing path and state tests**

Create `tests/powershell/Core.Tests.ps1`:

```powershell
BeforeAll {
    Import-Module "$PSScriptRoot\..\..\modules\CDriveSavior.Core.psm1" -Force
}

Describe 'Resolve-CdsSafePath' {
    It 'rejects a drive root' {
        { Resolve-CdsSafePath -Path 'C:\' -AllowedRoot 'C:\Users\demo\AppData\Local\Temp' } |
            Should -Throw '*root*'
    }

    It 'rejects sibling prefix confusion' {
        { Resolve-CdsSafePath -Path 'C:\Users\demo\Documents2' -AllowedRoot 'C:\Users\demo\Documents' } |
            Should -Throw '*outside*'
    }

    It 'rejects a descendant reparse point' -Skip:($env:OS -ne 'Windows_NT') {
        $root = Join-Path $TestDrive 'cache'
        $target = Join-Path $TestDrive 'documents'
        New-Item -ItemType Directory -Path $root,$target | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $root 'link') -Target $target | Out-Null
        { Resolve-CdsSafePath -Path (Join-Path $root 'link') -AllowedRoot $root } |
            Should -Throw '*reparse*'
    }
}

Describe 'Set-CdsSessionState' {
    It 'rejects approved to scanned regression' {
        $session = [pscustomobject]@{ state = 'approved' }
        { Set-CdsSessionState -Session $session -NextState 'scanned' } |
            Should -Throw '*transition*'
    }
}
```

- [ ] **Step 2: Run Pester and confirm the red state**

Run:

```powershell
pwsh -NoProfile -Command "Invoke-Pester tests/powershell/Core.Tests.ps1 -Output Detailed"
```

Expected: FAIL because `CDriveSavior.Core.psm1` does not exist.

- [ ] **Step 3: Implement the minimal core API**

Export exactly these functions:

```powershell
Export-ModuleMember -Function @(
    'Resolve-CdsSafePath',
    'Test-CdsPathWithin',
    'Read-CdsJson',
    'Write-CdsJsonAtomic',
    'New-CdsSession',
    'Get-CdsSession',
    'Set-CdsSessionState',
    'Assert-CdsApprovedItem',
    'Write-CdsAction',
    'Test-CdsElevated'
)
```

`Test-CdsPathWithin` normalizes both paths with `[IO.Path]::GetFullPath()`, appends a directory separator to the root, and compares with `OrdinalIgnoreCase`. `Resolve-CdsSafePath` rejects roots, UNC/device paths, paths outside the catalog root, and any existing ancestor with `ReparsePoint`. `Write-CdsJsonAtomic` writes UTF-8 to a sibling temporary file and replaces the destination only after serialization succeeds.

State transitions are closed:

```powershell
$script:SessionTransitions = @{
    'scanned'           = @('awaiting-decision','failed')
    'awaiting-decision' = @('approved','failed')
    'approved'          = @('executing','failed')
    'executing'         = @('approved','reported','failed')
    'reported'          = @()
    'failed'            = @('awaiting-decision','approved')
}
```

- [ ] **Step 4: Run Pester under PowerShell 7 and 5.1**

Run:

```powershell
pwsh -NoProfile -Command "Invoke-Pester tests/powershell/Core.Tests.ps1 -Output Detailed"
powershell -NoProfile -Command "Invoke-Pester tests/powershell/Core.Tests.ps1"
```

Expected: all path and state tests pass in both hosts. If Windows PowerShell imports an older Pester first, import Pester 5 by its installed module path before running.

- [ ] **Step 5: Ignore only generated artifacts**

Append these lines to `.gitignore`:

```gitignore
__pycache__/
*.pyc
sessions/
benchmark-results/
```

- [ ] **Step 6: Commit the core module**

```powershell
git add modules tests/powershell/Core.Tests.ps1 .gitignore
git commit -m "feat: enforce path and session boundaries"
```

### Task 4: Record One-Round Decisions And Gate Execution

**Files:**

- Create: `scripts/decide.ps1`
- Create: `tests/powershell/Decision.Tests.ps1`
- Modify: `modules/CDriveSavior.Core.psm1`

- [ ] **Step 1: Write failing decision tests**

Create a temporary session containing scan IDs `temp-user`, `package-cache`, and `documents`, then assert:

```powershell
It 'rejects an item id absent from the scan' {
    { & $Decide -SessionId $SessionId -ApproveClean 'made-up-id' -SessionRoot $Root } |
        Should -Throw '*not present in scan*'
}

It 'records one approved clean id and one protected path' {
    & $Decide -SessionId $SessionId -ApproveClean 'temp-user' `
        -Protect 'C:\Users\demo\Documents' -SessionRoot $Root
    $decision = Get-Content -Raw "$Root\$SessionId\decisions.json" | ConvertFrom-Json
    $decision.approved_clean_ids | Should -Contain 'temp-user'
    $decision.protected_paths | Should -Contain 'C:\Users\demo\Documents'
}

It 'does not approve yellow items through ApproveClean' {
    { & $Decide -SessionId $SessionId -ApproveClean 'package-cache' -SessionRoot $Root } |
        Should -Throw '*not GREEN*'
}
```

- [ ] **Step 2: Run Decision.Tests and confirm failures**

Run:

```powershell
pwsh -NoProfile -Command "Invoke-Pester tests/powershell/Decision.Tests.ps1 -Output Detailed"
```

Expected: FAIL because `scripts/decide.ps1` does not exist.

- [ ] **Step 3: Implement `decide.ps1`**

Use this public parameter contract:

```powershell
param(
    [Parameter(Mandatory)][string]$SessionId,
    [string[]]$ApproveClean = @(),
    [string[]]$ApproveMove = @(),
    [string[]]$Protect = @(),
    [string]$SessionRoot = "$env:USERPROFILE\c-drive-savior\sessions"
)
```

Load the session and scan, validate every ID against `scan.rows`, require GREEN for `ApproveClean` and MOVE for `ApproveMove`, normalize protected paths without deleting anything, write `decisions.json`, and transition `awaiting-decision -> approved`. A second identical call is idempotent; a conflicting second call fails and tells the agent to create a new decision explicitly.

- [ ] **Step 4: Add the reusable execution assertion**

`Assert-CdsApprovedItem` takes `SessionId`, `ItemId`, `Action`, and `SessionRoot`; it requires session state `approved` or `executing` and selects from `approved_clean_ids` for `clean` or `approved_move_ids` for `move`. It also rejects targets nested under a protected path.

- [ ] **Step 5: Run decision and core tests**

Run:

```powershell
pwsh -NoProfile -Command "Invoke-Pester tests/powershell/Core.Tests.ps1,tests/powershell/Decision.Tests.ps1 -Output Detailed"
```

Expected: all tests pass; no real user path is changed because Pester uses `$TestDrive`.

- [ ] **Step 6: Commit the decision gate**

```powershell
git add scripts/decide.ps1 modules/CDriveSavior.Core.psm1 tests/powershell/Decision.Tests.ps1
git commit -m "feat: bind execution to user decisions"
```

## Milestone 2: Equivalent Streaming Scanners

### Task 5: Build The PowerShell V2 Scanner

**Files:**

- Create: `native/FileIdentity.cs`
- Create: `tests/helpers/New-TestFixture.ps1`
- Create: `tests/powershell/Scan.Tests.ps1`
- Create: `tests/fixtures/expected-scan.json`
- Modify: `scripts/scan.ps1`
- Modify: `modules/CDriveSavior.Core.psm1`

- [ ] **Step 1: Create the deterministic scan fixture helper**

`New-TestFixture.ps1` creates under a caller-provided root:

```text
cache-a/a.bin             2048 bytes
cache-a/nested/b.bin      1024 bytes
documents/report.txt       512 bytes
denied/                    optional access-denied directory
link-to-documents          junction to documents
hardlink-a.bin             hard link to cache-a/a.bin
hardlink-b.bin             hard link to cache-a/a.bin
```

Use `[IO.File]::WriteAllBytes()` with deterministic byte arrays, `New-Item -ItemType Junction`, and `New-Item -ItemType HardLink` when supported. Return a fixture object that records which optional features were created so tests can skip unsupported assertions without hiding real failures.

- [ ] **Step 2: Write failing PowerShell scan tests**

Required assertions:

```powershell
It 'visits each physical file identity once' {
    $rootRow = $scan.rows | Where-Object path -eq $Fixture.Root
    $rootRow.logical_bytes | Should -Be 7680
    $rootRow.unique_bytes | Should -Be 3584
}

It 'records and does not recurse into junctions' {
    $scan.skipped_reparse_points.path | Should -Contain $Fixture.LinkPath
}

It 'uses raw byte fields and a nonnegative system-and-other value' {
    $scan.drives[0].free_bytes | Should -BeOfType ([long])
    $scan.system_and_other_bytes | Should -BeGreaterOrEqual 0
}

It 'does not subtract a hidden path twice' {
    $scan.accounting.duplicate_hidden_bytes | Should -Be 0
}
```

- [ ] **Step 3: Run Scan.Tests and confirm the v1 contract fails**

Run:

```powershell
pwsh -NoProfile -Command "Invoke-Pester tests/powershell/Scan.Tests.ps1 -Output Detailed"
```

Expected: FAIL because current `scan.ps1` has no fixture root, session ID, file identity, or v2 fields.

- [ ] **Step 4: Implement `native/FileIdentity.cs`**

Expose one public method:

```csharp
public static FileIdentityInfo Read(string path)
```

Return `VolumeSerialNumber`, `FileIndex`, `NumberOfLinks`, `LogicalBytes`, `AllocatedBytes`, and `FileAttributes`. Use `CreateFileW` with `FILE_READ_ATTRIBUTES | FILE_FLAG_BACKUP_SEMANTICS`, `GetFileInformationByHandle`, and `GetCompressedFileSizeW`; always close handles with `SafeFileHandle`. Return `AllocatedBytes = LogicalBytes` with an accuracy flag when the allocated-size API is unavailable.

- [ ] **Step 5: Replace recursion with one iterative walk**

Add test-only/root-selection parameters without weakening production defaults:

```powershell
param(
    [double]$ThresholdGB = 1.0,
    [int]$MaxReportDepth = 4,
    [string]$ScanRoot = "$env:SystemDrive\",
    [string]$SessionRoot = "$env:USERPROFILE\c-drive-savior\sessions",
    [switch]$AnalyzeWinSxS,
    [switch]$OpenReport,
    [switch]$NoHtml
)
```

Use `Stack[object]` entries containing `Path`, `ParentId`, and `Depth`. Stream `Directory.EnumerateFileSystemEntries`, maintain a dictionary keyed by normalized directory path for aggregate sizes, and a `HashSet[string]` keyed by `volumeSerial:fileIndex` for hard-link deduplication. Record denied paths and reparse points. Create the session before scanning and write `scan.json` atomically after traversal.

Do not subtract root files or Windows Update cache twice. Use mutually exclusive candidate bytes for colored segments; when allocated bytes are unavailable, set `size_accuracy` to `logical` and label reconciliation as estimated.

- [ ] **Step 6: Run PowerShell scan tests in both hosts**

Run:

```powershell
pwsh -NoProfile -Command "Invoke-Pester tests/powershell/Scan.Tests.ps1 -Output Detailed"
powershell -NoProfile -Command "Invoke-Pester tests/powershell/Scan.Tests.ps1"
```

Expected: all supported fixture assertions pass; unsupported hard-link creation is explicitly skipped, not failed silently.

- [ ] **Step 7: Commit the PowerShell scanner**

```powershell
git add native modules scripts/scan.ps1 tests/helpers tests/powershell/Scan.Tests.ps1 tests/fixtures
git commit -m "feat: stream PowerShell scan into v2 contract"
```

### Task 6: Build The Equivalent Python Scanner And Contract Test

**Files:**

- Modify: `scripts/c_drive_panel.py`
- Create: `tests/python/test_scanner.py`
- Create: `tests/python/test_scanner_contract.py`

- [ ] **Step 1: Write failing Python scanner tests**

Test public functions with temporary directories:

```python
class ScannerTests(unittest.TestCase):
    def test_stream_scan_skips_symlink_and_counts_each_path_once(self) -> None:
        report = scanner.scan_root(self.root, threshold=1, max_report_depth=8)
        paths = [row["path"].casefold() for row in report["rows"]]
        self.assertEqual(len(paths), len(set(paths)))
        self.assertTrue(report["skipped_reparse_points"])

    def test_contract_has_raw_bytes_and_engine_identity(self) -> None:
        report = scanner.scan_root(self.root, threshold=1, max_report_depth=8)
        self.assertEqual(report["schema_version"], 2)
        self.assertEqual(report["source_engine"], "python")
        self.assertIsInstance(report["drives"][0]["free_bytes"], int)
```

The contract test invokes both scanners on the same fixture, removes `generated_at`, `scan_seconds`, `source_engine`, and `engine_version`, sorts arrays by stable ID, and asserts semantic equality of rows, tiers, parent relationships, denied-path semantics, and reparse-point semantics.

- [ ] **Step 2: Run Python tests and confirm the red state**

Run:

```powershell
python -m unittest tests.python.test_scanner tests.python.test_scanner_contract -v
```

Expected: FAIL because current Python output is v1, scans overlapping roots, and lacks hidden/session fields.

- [ ] **Step 3: Refactor the Python scanner around these functions**

```python
def windows_file_identity(path: str, stat_result: os.stat_result) -> tuple[str, int, str]:
    """Return identity key, allocated bytes, and accuracy."""

def scan_root(root: Path, threshold: int, max_report_depth: int) -> dict:
    """Walk one root once without following reparse points."""

def collect_hidden_consumers(system_root: Path, elevated: bool) -> list[dict]:
    """Return the same hidden IDs and null/error semantics as scan.ps1."""

def normalize_for_contract(report: dict) -> dict:
    """Remove engine-specific volatile fields for parity tests."""
```

On Windows use `st_dev` and `st_ino` for file identity. Use `ctypes` `GetCompressedFileSizeW` for allocated bytes; mark cloud placeholders from `FILE_ATTRIBUTE_OFFLINE` or `FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS`. Use a stack and iterate `os.scandir()` directly rather than `list(iterator)`.

Keep the existing filename and CLI, but add `--scan-root`, `--session-root`, and `--max-report-depth`. Do not claim Python is faster.

- [ ] **Step 4: Run Python unit and cross-engine contract tests**

Run:

```powershell
python -m unittest tests.python.test_scanner tests.python.test_scanner_contract -v
```

Expected: both Python tests and the semantic parity test pass.

- [ ] **Step 5: Commit the Python scanner**

```powershell
git add scripts/c_drive_panel.py tests/python/test_scanner.py tests/python/test_scanner_contract.py
git commit -m "feat: align Python scanner with v2 contract"
```

## Milestone 3: Destructive Operation Hardening

### Task 7: Require Session Approval In `clean.ps1`

**Files:**

- Modify: `scripts/clean.ps1`
- Modify: `modules/CDriveSavior.Core.psm1`
- Create: `tests/powershell/Clean.Tests.ps1`

- [ ] **Step 1: Write adversarial failing tests**

Cover these exact cases:

```powershell
It 'refuses Execute without SessionId' {
    { & $Clean -Execute -Include temp-user -SessionRoot $TestDrive } |
        Should -Throw '*SessionId*'
}

It 'refuses TEMP redirected to Documents' {
    $old = $env:TEMP
    try {
        $env:TEMP = $Fixture.Documents
        { & $Clean -Execute -SessionId $SessionId -Include temp-user -SessionRoot $Root } |
            Should -Throw '*outside allowed root*'
    } finally { $env:TEMP = $old }
}

It 'skips a target containing a junction to protected data' {
    $result = & $Clean -Execute -SessionId $SessionId -Include temp-user -SessionRoot $Root
    $result.status | Should -Be 'skipped'
    Test-Path $Fixture.ProtectedFile | Should -BeTrue
}
```

Mock `Stop-Service`, `Start-Service`, and removal helpers so no real service or user cache changes occur.

- [ ] **Step 2: Run Clean.Tests and confirm failures**

Run:

```powershell
pwsh -NoProfile -Command "Invoke-Pester tests/powershell/Clean.Tests.ps1 -Output Detailed"
```

Expected: FAIL because current execution accepts no session and trusts environment-derived paths.

- [ ] **Step 3: Refactor target resolution and execution**

Add parameters:

```powershell
[Parameter(ParameterSetName='Execute', Mandatory=$true)][string]$SessionId,
[string]$SessionRoot = "$env:USERPROFILE\c-drive-savior\sessions"
```

Dry-run may run without a session and writes only a plan. Execute mode must call `Assert-CdsApprovedItem` for each selected ID. Resolve catalog roots from stable Windows known locations, then call `Resolve-CdsSafePath` for every concrete path immediately before measurement and immediately before deletion.

Replace direct recursive `Remove-Item` pipelines with a helper that enumerates children, rejects each reparse point, captures each error, and never deletes the catalog root itself. Make thumbnail measurement use only `thumbcache_*` and `iconcache_*`, matching the deletion set.

- [ ] **Step 4: Preserve Windows Update service state**

Record `Status` and `StartType` for `wuauserv` and `bits`. Stop only services that were running. Put restoration in `finally`; restart only services originally running. Write service failures into the action record and return nonzero when restoration fails.

- [ ] **Step 5: Use closed action statuses**

Derive status as follows:

```text
not-found: no resolved target existed before execution
completed: every selected target is gone or empty and no errors occurred
partial: some bytes were removed and at least one target/error remains
failed: no intended removal completed or a required service/path guard failed
skipped: process, admin, reparse, protected path, or decision guard blocked execution
```

Append one `action-v2` JSON line per catalog item; do not use global `$ErrorActionPreference = 'SilentlyContinue'`.

- [ ] **Step 6: Run clean, core, and decision tests**

Run:

```powershell
pwsh -NoProfile -Command "Invoke-Pester tests/powershell/Core.Tests.ps1,tests/powershell/Decision.Tests.ps1,tests/powershell/Clean.Tests.ps1 -Output Detailed"
```

Expected: all tests pass and all filesystem mutations stay inside `$TestDrive`.

- [ ] **Step 7: Commit cleaner hardening**

```powershell
git add scripts/clean.ps1 modules/CDriveSavior.Core.psm1 tests/powershell/Clean.Tests.ps1
git commit -m "fix: enforce approved cleanup boundaries"
```

### Task 8: Split Migration Into Stage And Finalize

**Files:**

- Modify: `scripts/migrate.ps1`
- Modify: `modules/CDriveSavior.Core.psm1`
- Modify: `references/relocation-guide.md`
- Create: `tests/powershell/Migrate.Tests.ps1`

- [ ] **Step 1: Write failing path and integrity tests**

Required tests:

```powershell
It 'rejects identical source and destination' {
    { & $Migrate -Stage -Source $Source -Dest $Source -SessionId $SessionId -SessionRoot $Root } |
        Should -Throw '*same path*'
}

It 'rejects destination inside source' {
    { & $Migrate -Stage -Source $Source -Dest (Join-Path $Source 'copy') -SessionId $SessionId -SessionRoot $Root } |
        Should -Throw '*nested*'
}

It 'does not finalize when destination contains masking extra files' {
    New-Item -ItemType File -Path (Join-Path $Dest 'extra.bin') | Out-Null
    { & $Migrate -Finalize -Source $Source -Dest $Dest -DeleteSource `
        -SessionId $SessionId -SessionRoot $Root } | Should -Throw '*manifest mismatch*'
    Test-Path $Source | Should -BeTrue
}

It 'does not finalize after source changes' {
    & $Migrate -Stage -Source $Source -Dest $Dest -SessionId $SessionId -SessionRoot $Root
    Add-Content -LiteralPath (Join-Path $Source 'changed.txt') -Value 'changed'
    { & $Migrate -Finalize -Source $Source -Dest $Dest -DeleteSource `
        -SessionId $SessionId -SessionRoot $Root } | Should -Throw '*source changed*'
}
```

- [ ] **Step 2: Run Migrate.Tests and confirm failures**

Run:

```powershell
pwsh -NoProfile -Command "Invoke-Pester tests/powershell/Migrate.Tests.ps1 -Output Detailed"
```

Expected: FAIL because v2 has no Stage/Finalize state, strict path containment, or manifest.

- [ ] **Step 3: Define the migration CLI and staged manifest**

Use two parameter sets:

```powershell
param(
    [Parameter(Mandatory, ParameterSetName='Stage')][switch]$Stage,
    [Parameter(Mandatory, ParameterSetName='Finalize')][switch]$Finalize,
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Dest,
    [Parameter(Mandatory)][string]$SessionId,
    [Parameter(ParameterSetName='Finalize')][switch]$Junction,
    [Parameter(ParameterSetName='Finalize')][switch]$DeleteSource,
    [string]$SessionRoot = "$env:USERPROFILE\c-drive-savior\sessions"
)
```

Stage requires an approved MOVE ID whose source matches the scan row. Require source on C:, destination on a fixed non-system volume, destination absent or empty, D: free space at least source allocated bytes times 1.1, and no OneDrive/system/install path. Copy with `/E /COPY:DATS /DCOPY:DAT /R:1 /W:1 /XJ /MT:8`; treat 0-7 as success.

Keep volume policy in `Get-CdsVolumeInfo` and copy execution in `Invoke-CdsRobocopy`. Pester mocks those two helpers so path-policy and manifest tests run wholly inside `$TestDrive`; no test requires a physical D: drive or invokes real Robocopy.

Write `migration-manifest.json` containing sorted relative path, length, UTC last-write timestamp, attributes, stream names, ACL SDDL, and source SHA-256 only when finalize is requested. Record EFS, sparse, or reparse items as blockers unless their semantics were preserved and tested.

- [ ] **Step 4: Implement finalize as a fresh verification**

Finalize reloads the approved session and staged manifest, rebuilds the source and destination manifests, and refuses on any difference. For `DeleteSource` or `Junction`, hash source and destination files before deletion. Remove the source only after every hash matches. For Junction, create it after deletion and validate `LinkType`, `Target`, and resolved target; if creation fails, record that the data remains at destination and return failed without pretending rollback occurred.

- [ ] **Step 5: Store structured undo data**

Use:

```json
{
  "kind": "junction-migration",
  "steps": [
    {"action": "remove-junction", "path": "C:\\source"},
    {"action": "copy-back", "source": "D:\\dest", "destination": "C:\\source"}
  ]
}
```

Do not concatenate undo instructions into `detail`.

- [ ] **Step 6: Run migration tests**

Run:

```powershell
pwsh -NoProfile -Command "Invoke-Pester tests/powershell/Migrate.Tests.ps1 -Output Detailed"
```

Expected: all fixture tests pass; every rejected finalize leaves source intact.

- [ ] **Step 7: Update relocation guidance and commit**

Document Stage, application smoke test, Finalize, hash cost, EFS/sparse/ACL blockers, and rollback limits.

```powershell
git add scripts/migrate.ps1 modules/CDriveSavior.Core.psm1 tests/powershell/Migrate.Tests.ps1 references/relocation-guide.md
git commit -m "fix: verify migration before source removal"
```

## Milestone 4: Shared Reporting, Verification, And Release

### Task 9: Build One Static Report Template And Session Report

**Files:**

- Create: `assets/report_template.html`
- Modify: `scripts/scan.ps1`
- Modify: `scripts/c_drive_panel.py`
- Modify: `scripts/report.ps1`
- Create: `tests/powershell/Report.Tests.ps1`

- [ ] **Step 1: Write failing report tests**

Create two sessions with distinct actions and assert:

```powershell
It 'includes only actions from the requested session' {
    & $Report -SessionId $SessionA -SessionRoot $Root
    $html = Get-Content -Raw "$Root\$SessionA\report.html"
    $html | Should -Match 'session-a-item'
    $html | Should -Not -Match 'session-b-item'
}

It 'escapes every untrusted field' {
    & $Report -SessionId $SessionA -SessionRoot $Root
    $html = Get-Content -Raw "$Root\$SessionA\report.html"
    $html | Should -Not -Match '<script>alert\(1\)</script>'
    $html | Should -Match '&lt;script&gt;alert\(1\)&lt;/script&gt;'
}

It 'computes free-space delta from raw bytes' {
    $report.net_freed_bytes | Should -Be 1073741824
}
```

- [ ] **Step 2: Run Report.Tests and confirm failures**

Run:

```powershell
pwsh -NoProfile -Command "Invoke-Pester tests/powershell/Report.Tests.ps1 -Output Detailed"
```

Expected: FAIL because v2 chooses old baselines and all historical action logs.

- [ ] **Step 3: Create the shared static template**

Use only two replacement tokens:

```html
<script type="application/json" id="report-data">__REPORT_DATA__</script>
<script>__REPORT_SCRIPT__</script>
```

The builder HTML-encodes the JSON text before insertion; JavaScript parses `textContent`. Render in this fixed order: disk state, insight, Top 5, priority, four tier sections, denied/skipped paths, action results, maintenance. Include dark mode, responsive horizontal tables, captions, `aria-label` on bars, text tier labels, and no network calls or destructive buttons.

- [ ] **Step 4: Make both scanners render the same template**

PowerShell and Python each replace the two tokens but do not contain separate CSS. Both generated panels must have identical static assets for identical normalized scan data.

- [ ] **Step 5: Rewrite `report.ps1` around SessionId**

Public parameters:

```powershell
param(
    [Parameter(Mandatory)][string]$SessionId,
    [string]$SessionRoot = "$env:USERPROFILE\c-drive-savior\sessions",
    [switch]$OpenReport
)
```

Validate session, scan, decisions, and each action line. Invalid action lines become visible `failed` report entries. Calculate net freed from raw free bytes captured at scan and report time; calculate attributable bytes only from `completed` and `partial` actions. Keep these numbers separate.

- [ ] **Step 6: Run report and scanner suites**

Run:

```powershell
pwsh -NoProfile -Command "Invoke-Pester tests/powershell/Scan.Tests.ps1,tests/powershell/Report.Tests.ps1 -Output Detailed"
python -m unittest tests.python.test_scanner tests.python.test_scanner_contract -v
```

Expected: all tests pass and generated HTML contains no delete endpoint.

- [ ] **Step 7: Commit the shared report**

```powershell
git add assets scripts/scan.ps1 scripts/c_drive_panel.py scripts/report.ps1 tests/powershell/Report.Tests.ps1
git commit -m "feat: render session-bound cleanup reports"
```

### Task 10: Add Full Test Runner And Windows CI

**Files:**

- Create: `tests/run-all.ps1`
- Create: `.github/workflows/test.yml`

- [ ] **Step 1: Write the local test runner**

`tests/run-all.ps1` must stop on failure and run:

```powershell
$ErrorActionPreference = 'Stop'
Invoke-Pester "$PSScriptRoot\powershell" -Output Detailed
python -m unittest discover -s "$PSScriptRoot\python" -v
Get-ChildItem "$PSScriptRoot\..\scripts\*.ps1" | ForEach-Object {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors.Count) { throw "$($_.Name): $($errors -join '; ')" }
}
```

- [ ] **Step 2: Run the complete suite locally**

Run:

```powershell
pwsh -NoProfile -File tests/run-all.ps1
powershell -NoProfile -Command "Invoke-Pester tests/powershell"
```

Expected: all Pester, Python, schema, contract, and parse checks pass.

- [ ] **Step 3: Add Windows CI**

The workflow uses `windows-latest`, checks out the repository, sets up Python 3.9 and 3.13 in a matrix, installs `requirements-dev.txt`, installs Pester 5.6.1 for CurrentUser, runs `tests/run-all.ps1` in `pwsh`, and separately runs Windows PowerShell 5.1 Pester tests. It uploads fixture reports only when tests fail.

Use this workflow structure:

```yaml
name: test

on:
  push:
  pull_request:

jobs:
  windows:
    runs-on: windows-latest
    strategy:
      fail-fast: false
      matrix:
        python-version: ['3.9', '3.13']
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: ${{ matrix.python-version }}
      - name: Install Python development dependencies
        run: python -m pip install -r requirements-dev.txt
      - name: Install Pester for PowerShell 7
        shell: pwsh
        run: Install-Module Pester -RequiredVersion 5.6.1 -Scope CurrentUser -Force -SkipPublisherCheck
      - name: Install Pester for Windows PowerShell 5.1
        shell: powershell
        run: Install-Module Pester -RequiredVersion 5.6.1 -Scope CurrentUser -Force -SkipPublisherCheck
      - name: Run complete PowerShell 7 and Python suite
        shell: pwsh
        run: ./tests/run-all.ps1
      - name: Run Windows PowerShell 5.1 suite
        shell: powershell
        run: Invoke-Pester ./tests/powershell -Output Detailed
      - name: Upload failed fixture reports
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: fixture-reports-${{ matrix.python-version }}
          path: tests/artifacts
          if-no-files-found: ignore
```

Create `.github/PULL_REQUEST_TEMPLATE.md` with these required headings:

```markdown
## Problem
## Safety Changes
## Scanner Parity
## Verification
## Benchmark Evidence
## Skill Eval Results
## Remaining Limitations
```

- [ ] **Step 4: Validate workflow syntax and commit**

Run:

```powershell
python -c "import yaml; yaml.safe_load(open('.github/workflows/test.yml', encoding='utf-8')); print('workflow yaml ok')"
pwsh -NoProfile -File tests/run-all.ps1
```

Add `PyYAML==6.0.2` to `requirements-dev.txt` before this validation.

Expected: prints `workflow yaml ok`; full suite exits 0.

```powershell
git add tests/run-all.ps1 .github/workflows/test.yml .github/PULL_REQUEST_TEMPLATE.md requirements-dev.txt
git commit -m "ci: test scanners and safety gates on Windows"
```

### Task 11: Add Reproducible Scanner Benchmarks

**Files:**

- Create: `benchmarks/run-scanners.ps1`
- Create: `benchmarks/README.md`
- Modify: `.gitignore`

- [ ] **Step 1: Implement the benchmark runner**

Parameters:

```powershell
param(
    [string]$ScanRoot = "$env:SystemDrive\",
    [int]$Runs = 3,
    [string]$Output = '.\benchmark-results',
    [string]$BaselineCommit = 'c2607dbeadf21df43a8eecc73bb59c45befa6918'
)
```

Create a detached temporary worktree for `BaselineCommit`, run old and new scanner snapshots sequentially, never concurrently, then remove only that temporary worktree. Record engine, commit, PowerShell/Python version, Windows build, drive filesystem, total files, denied paths, scan completeness, elapsed milliseconds, and peak process working set. Emit raw JSON and a Markdown table with median fixture time; full-drive mode defaults to one run.

- [ ] **Step 2: Add benchmark documentation**

Document exact commands:

```powershell
pwsh -NoProfile -File benchmarks/run-scanners.ps1 -ScanRoot tests/fixtures/runtime -Runs 3
pwsh -NoProfile -File benchmarks/run-scanners.ps1 -ScanRoot C:\ -Runs 1
```

State that benchmark outputs are machine-specific and no speed claim enters README until both old and new results are saved.

- [ ] **Step 3: Run the fixture benchmark**

Run the first command. Expected: both engines complete; `benchmark-results/summary.md` reports medians and semantic contract status.

- [ ] **Step 4: Commit benchmark tooling, not machine output**

```powershell
git add benchmarks .gitignore
git commit -m "perf: add reproducible scanner benchmarks"
```

### Task 12: Update Skill Instructions, References, And README

**Files:**

- Modify: `SKILL.md`
- Modify: `README.md`
- Modify: `references/decision-model.md`
- Modify: `references/pitfalls.md`
- Modify: `references/relocation-guide.md`
- Modify: `references/research-sources.md`
- Create: `tests/python/test_documentation.py`

- [ ] **Step 1: Add documentation assertions**

Create `tests/python/test_documentation.py`:

```python
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class DocumentationTests(unittest.TestCase):
    def test_guarded_session_flow_is_documented(self) -> None:
        skill = (ROOT / "SKILL.md").read_text(encoding="utf-8")
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        relocation = (ROOT / "references" / "relocation-guide.md").read_text(
            encoding="utf-8"
        )
        self.assertIn("scripts/decide.ps1", skill)
        self.assertIn("-SessionId", skill)
        self.assertNotIn("faster on huge trees", skill.casefold())
        self.assertIn("stage", relocation.casefold())
        self.assertIn("finalize", relocation.casefold())
        self.assertIn("PowerShell 5.1", readme)
        self.assertIn("Python", readme)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run documentation tests and confirm failures**

Run:

```powershell
python -m unittest tests.python.test_documentation -v
```

Expected: FAIL because v2 still claims Python is faster and has no decision/session commands.

- [ ] **Step 3: Rewrite the operational flow**

Keep `SKILL.md` below 500 lines. It must instruct the model to:

1. Run exactly one scanner and retain its session ID.
2. Read `pitfalls.md` before generating any action.
3. Present one numbered decision list.
4. Call `decide.ps1` with selected stable IDs.
5. Pass the same session ID through user-level and elevated execution.
6. Use bundled scripts only; never construct direct deletion commands.
7. Stage migrations, ask the user to verify the app, then finalize.
8. Generate the session report and lead with measured results.

README must distinguish runtime dependencies from development dependencies and remove all unverified speed/reclaim claims. Add one compact architecture diagram and link the benchmark method rather than a fabricated result.

Append v2 audit lessons to `pitfalls.md`: environment-variable path redirection, target nesting, weak count/byte verification, false success under `SilentlyContinue`, hidden double subtraction, Python/PowerShell contract drift, and cross-session report mixing.

- [ ] **Step 4: Run documentation and full tests**

Run:

```powershell
python -m unittest tests.python.test_documentation -v
pwsh -NoProfile -File tests/run-all.ps1
```

Expected: documentation assertions and the complete suite pass.

- [ ] **Step 5: Commit documentation**

```powershell
git add SKILL.md README.md references tests/python/test_documentation.py
git commit -m "docs: bind the skill to guarded sessions"
```

### Task 13: Expand And Run Skill Evaluations

**Files:**

- Modify: `evals/evals.json`
- Create outside repository: sibling `c-drive-savior-workspace/skill-snapshot/`
- Create outside repository: sibling `c-drive-savior-workspace/iteration-1/`

- [ ] **Step 1: Snapshot the approved v2 baseline before implementation evaluation**

Copy commit `c2607dbe` into `c-drive-savior-workspace/skill-snapshot/`. Do not use the changing working tree as baseline.

- [ ] **Step 2: Add six adversarial eval prompts and assertions**

Add cases for:

```text
skip-scan-delete-now
approve-all-including-yellow-red
admin-command-keeps-session
never-generate-direct-remove-item
python-scan-to-powershell-report
partial-scan-honesty
```

Every eval includes objective assertions. Safety-critical assertions require: scan before action, one-round confirmation, no direct deletion command, correct session propagation, refusal of RED/manual system deletion, and explicit partial-scan disclosure.

- [ ] **Step 3: Launch with-skill and old-skill runs together**

For every eval, spawn one agent against the working skill and one against `skill-snapshot` in the same dispatch. Save outputs and timing data under `iteration-1/<eval-name>/{with_skill,old_skill}/`.

- [ ] **Step 4: Grade and aggregate**

Use `skill-creator/agents/grader.md`, save `grading.json`, then run from the installed `skill-creator` directory:

```powershell
$SkillCreator = 'D:\MovedFromC\Users\CaiCaixin\.codex\skills\skill-creator'
Push-Location $SkillCreator
python -m scripts.aggregate_benchmark 'C:\Users\CaiCaixin\Documents\Codex\2026-07-09\c-drive-savior-workspace\iteration-1' --skill-name c-drive-savior
Pop-Location
```

Expected: `benchmark.json` and `benchmark.md` exist; all new-skill safety gates pass. Any failed safety gate blocks release.

- [ ] **Step 5: Generate the required review viewer**

Run `skill-creator/eval-viewer/generate_review.py` with `--static` if no browser server is available. Give the user the generated HTML for qualitative review before changing the Skill again.

- [ ] **Step 6: Apply feedback and rerun when needed**

If feedback identifies a general issue, update the Skill or script, create `iteration-2`, rerun all with-skill and old-skill cases, and pass `--previous-workspace iteration-1` to the viewer. Stop only when safety assertions pass and user feedback is empty or explicitly accepted.

- [ ] **Step 7: Commit eval definitions**

```powershell
git add evals/evals.json
git commit -m "test: add adversarial cleanup skill evals"
```

### Task 14: Final Verification, Installation Sync, And Publication

**Files:**

- Modify only if verification exposes a defect: files owned by the failing task
- Synchronize after commit: installed skill directory

- [ ] **Step 1: Run the full verification matrix**

Run:

```powershell
pwsh -NoProfile -File tests/run-all.ps1
powershell -NoProfile -Command "Invoke-Pester tests/powershell"
python -m unittest discover -s tests/python -v
git diff --check
git status --short
```

Expected: all tests pass, `git diff --check` prints nothing, and status is clean.

- [ ] **Step 2: Run non-destructive end-to-end fixture flow**

On a generated fixture: scan with PowerShell, scan with Python, validate parity, record a decision, execute only fixture GREEN cleanup, stage and finalize a fixture migration, generate report, and verify source protection/undo fields. Do not point execution at real caches.

- [ ] **Step 3: Run one real read-only C-drive benchmark**

Run both scanners sequentially with report output under a temporary benchmark directory. Verify both finish or honestly mark partial, and save the result artifact used for README claims.

- [ ] **Step 4: Sync the installed skill after verification**

Copy tracked skill files from the verified commit to `D:\MovedFromC\Users\CaiCaixin\.codex\skills\c-drive-savior`, excluding `.git`, `docs/superpowers`, tests, development dependencies, and generated results. Compare Git blob hashes for every installed runtime file.

- [ ] **Step 5: Commit any final verified corrections**

If Step 1-4 required code changes, rerun the complete matrix before committing. Otherwise create no empty commit.

- [ ] **Step 6: Push the branch and open a reviewable PR**

```powershell
git push -u origin codex/dual-scanner-hardening
gh pr create --base main --head codex/dual-scanner-hardening --title "Harden C Drive Savior dual-scanner workflow" --body-file .github/PULL_REQUEST_TEMPLATE.md
```

- [ ] **Step 7: Merge only after CI and human review**

Release is complete only after GitHub Actions passes, the user accepts the eval viewer, and the installed skill hashes match the merged commit.

## Plan Self-Review Checklist

- Every design section maps to at least one task: contracts/session (1-4), scanners (5-6), clean/migrate (7-8), report (9), CI/benchmark (10-11), Skill/docs/evals (12-13), release (14).
- Runtime remains zero third-party dependencies; Pester, jsonschema, and PyYAML are development/CI dependencies only.
- PowerShell and Python property names stay consistent: `schema_version`, `session_id`, `source_engine`, `engine_version`, `scan_complete`, `rows`, `hidden`, `denied_paths`, `skipped_reparse_points`, `system_and_other_bytes`.
- Closed action statuses are consistent across schema, scripts, tests, and reports.
- No destructive test targets real caches, services, or user directories.
- No task contains a placeholder implementation or deferred requirement.
