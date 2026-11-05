param(
    [string]$ProjectDir = (Get-Location).Path,
    [string]$ReportCommit = 'de52be083cda90f7467389514b3025835f33c629'
)
$ErrorActionPreference = 'Stop'
$ProjectDir = (Resolve-Path -LiteralPath $ProjectDir).Path
foreach ($name in @('CMakeLists.txt','history.bundle','scripts/Run-WindowsChecks.ps1','docs/REPORT.md')) {
    if (!(Test-Path -LiteralPath (Join-Path $ProjectDir $name))) { throw ('Run from the fixed project root: missing ' + $name) }
}
$Evidence = Get-ChildItem -LiteralPath (Join-Path $ProjectDir 'evidence') -Directory |
    Where-Object { $_.Name -like 'windows-*' } | Sort-Object Name -Descending | Select-Object -First 1
if (!$Evidence) { throw 'No completed Windows evidence directory was found.' }
function Read-Json([string]$File) { Get-Content -LiteralPath $File -Raw -Encoding UTF8 | ConvertFrom-Json }
$SyncReport = Read-Json (Join-Path $Evidence.FullName '1gb-sync.json')
$StreamReport = Read-Json (Join-Path $Evidence.FullName '1gb-streaming.json')
foreach ($Report in @($SyncReport,$StreamReport)) {
    if (!$Report.accepted -or $Report.input_bytes -ne 1003898922 -or $Report.runs.Count -ne 1) { throw 'Large-file benchmark is not accepted.' }
    $Run = $Report.runs[0]
    if (!$Run.completed -or $Run.rows_imported -ne 9990000 -or $Run.rows_skipped -ne 10000 -or $Run.errors_recorded -ne 10000 -or
        $Run.peak_rss_bytes -le 0 -or $Run.peak_rss_bytes -ge 50000000 -or $Run.peak_commit_bytes -ge 50000000) { throw 'Unexpected row counts or memory measurements.' }
    if (!(Test-Path -LiteralPath $Run.journal)) { throw ('Missing complete error journal: ' + $Run.journal) }
}
$ExpectedDataHash = '89fa6c306b9730ea71a782da699c64cec1efc6b4097852bb457bc30abc9477d0'
foreach ($mode in @('sync','streaming')) {
    $lines = Get-Content -LiteralPath (Join-Path $Evidence.FullName ('1gb-' + $mode + '-verified.log'))
    $records = @($lines | Where-Object { $_.TrimStart().StartsWith('{') } | ForEach-Object { $_ | ConvertFrom-Json })
    if ($records.Count -ne 1 -or $records[0].verified_errors -ne 10000 -or $records[0].sha256 -ne $ExpectedDataHash) { throw ('Original data audit did not pass for ' + $mode) }
}
foreach ($config in @('Release','Debug')) {
    $log = Get-Content -LiteralPath (Join-Path $Evidence.FullName ($config + '-tests.log')) -Raw
    if (!$log.Contains('100% tests passed, 0 tests failed out of 61')) { throw ($config + ' test evidence is incomplete.') }
}
$repeats = Get-Content -LiteralPath (Join-Path $Evidence.FullName 'repeat100.log') -Raw
if ([regex]::Matches($repeats,'\[\s+PASSED\s+\]\s+61 tests\.').Count -ne 100 -or $repeats.Contains('[  FAILED  ]')) { throw 'The repeated-test log is incomplete.' }

# Fetch only documents/evidence from the approved delivery repository. No source code is changed.
$Base = 'https://raw.githubusercontent.com/yellowfishtomato/-/' + $ReportCommit + '/csv-homework/'
$Files = @(
    @('REPORT-final.md','docs/REPORT.md'),
    @('README-final.md','README.md'),
    @('VALIDATION-final.json','evidence/VALIDATION.json'),
    @('windows-user-measurements.json','evidence/windows-user-measurements.json'),
    @('windows-user-console-summary.log','evidence/windows-user-console-summary.log'),
    @('windows-user-initial-console.log','evidence/windows-user-initial-console.log')
)
$Incoming = Join-Path $env:TEMP ('csvp-final-documents-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Incoming | Out-Null
foreach ($Pair in $Files) {
    Invoke-WebRequest -UseBasicParsing -Uri ($Base + $Pair[0]) -OutFile (Join-Path $Incoming $Pair[0])
}
foreach ($Pair in $Files) {
    Copy-Item -LiteralPath (Join-Path $Incoming $Pair[0]) -Destination (Join-Path $ProjectDir $Pair[1]) -Force
}

# Append the exact local JSON values; console excerpts contain rounded times.
$LocalMeasurements = [pscustomobject]@{
    evidence_directory = $Evidence.Name
    original_file_sha256 = $ExpectedDataHash
    sync = $SyncReport
    streaming = $StreamReport
    hundred_thousand = (Read-Json (Join-Path $Evidence.FullName '100k-after.json'))
    release_debug_tests = 61
    shuffled_repeat_iterations = 100
    provenance = 'Read directly from existing user-local Windows JSON/log files; benchmarks were not rerun.'
}
$Utf8 = [Text.UTF8Encoding]::new($true)
[IO.File]::WriteAllText((Join-Path $ProjectDir 'evidence/windows-final-local-summary.json'), ($LocalMeasurements | ConvertTo-Json -Depth 15), $Utf8)
$Sync = $SyncReport.runs[0]
$Streaming = $StreamReport.runs[0]
$RawTable = @"
### Windows raw JSON measurements

| Mode | elapsed_ms | peak_working_set_bytes | peak_commit_bytes | imported | skipped | verified_errors |
|---|---:|---:|---:|---:|---:|---:|
| Sync | $($Sync.elapsed_ms) | $($Sync.peak_rss_bytes) | $($Sync.peak_commit_bytes) | $($Sync.rows_imported) | $($Sync.rows_skipped) | 10000 |
| Streaming | $($Streaming.elapsed_ms) | $($Streaming.peak_rss_bytes) | $($Streaming.peak_commit_bytes) | $($Streaming.rows_imported) | $($Streaming.rows_skipped) | 10000 |

Source: evidence/$($Evidence.Name); full JSON/error journals are included unchanged.
"@
$ReportFile = Join-Path $ProjectDir 'docs/REPORT.md'
$ReportText = Get-Content -LiteralPath $ReportFile -Raw -Encoding UTF8
$Pattern = '(?s)<!-- WINDOWS_RAW_METRICS_BEGIN -->.*?<!-- WINDOWS_RAW_METRICS_END -->'
if (![regex]::IsMatch($ReportText,$Pattern)) { throw 'Final report marker is missing.' }
$Replacement = '<!-- WINDOWS_RAW_METRICS_BEGIN -->' + [Environment]::NewLine + $RawTable + [Environment]::NewLine + '<!-- WINDOWS_RAW_METRICS_END -->'
# MatchEvaluator avoids treating dollar signs in replacement text as regex substitutions.
$ReportText = [regex]::Replace($ReportText,$Pattern,[Text.RegularExpressions.MatchEvaluator]{ param($m) $Replacement })
[IO.File]::WriteAllText($ReportFile,$ReportText,$Utf8)

$Tag = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,6)
$ZipPath = Join-Path (Split-Path $ProjectDir -Parent) ('csv-import-pipeline-submission-' + $Tag + '.zip')
$Items = @('CMakeLists.txt','README.md','.gitignore','.gitattributes','history.bundle','HISTORY_TRANSFER.md','ORIGINAL_DATA_PATH.txt','include','src','tests','bench','scripts','docs','evidence','data','third_party')
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$Output = [IO.File]::Open($ZipPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
$Archive = [IO.Compression.ZipArchive]::new($Output,[IO.Compression.ZipArchiveMode]::Create,$false,[Text.Encoding]::UTF8)
$RootPrefix = $ProjectDir.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$Added = 0
try {
    foreach ($Item in $Items) {
        $Path = Join-Path $ProjectDir $Item
        if (!(Test-Path -LiteralPath $Path)) { continue }
        $Entries = @(Get-Item -LiteralPath $Path)
        if ($Entries[0].PSIsContainer) { $Entries = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force) }
        foreach ($File in $Entries) {
            $Relative = $File.FullName.Substring($RootPrefix.Length).Replace('\','/')
            if ($Relative -match '(^|/)(\.git|\.vs|__pycache__|build[^/]*|out)/' -or $File.Name -ieq 'sample_1gb.csv') { continue }
            if ($File.Length -gt 50000000) { throw ('Unexpected large file in submission: ' + $Relative) }
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($Archive,$File.FullName,('csv-import-pipeline/' + $Relative),[IO.Compression.CompressionLevel]::Optimal) | Out-Null
            $Added++
        }
    }
} finally { $Archive.Dispose(); $Output.Dispose() }
$WpsPath = [IO.Path]::ChangeExtension($ZipPath,'txt')
Copy-Item -LiteralPath $ZipPath -Destination $WpsPath
Write-Host ''
Write-Host 'Final report and submission package are ready.' -ForegroundColor Green
Write-Host ('Files included: ' + $Added)
Write-Host ('ZIP: ' + $ZipPath)
Write-Host ('WPS attachment (same ZIP bytes, .txt suffix): ' + $WpsPath)
Write-Host 'Build directories and the original 1 GB CSV were excluded. Tested source code was not changed.'
