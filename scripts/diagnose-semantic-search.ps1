[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ProjectRoot,

    [string]$Query = "semantic search diagnostic query",
    [string]$Task = "Diagnose semantic search latency",
    [ValidateRange(1, 1800)]
    [int]$TimeoutSeconds = 330,
    [string]$OutputDirectory = (Join-Path (Get-Location) "lean-ctx-diagnostics")
)

$ErrorActionPreference = "Stop"

$resolvedRoot = (Resolve-Path -LiteralPath $ProjectRoot -ErrorAction Stop).Path
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$resolvedOutput = (Resolve-Path -LiteralPath $OutputDirectory).Path
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$summaryPath = Join-Path $resolvedOutput "summary-$timestamp.txt"

$oldPhaseTiming = $env:LEAN_CTX_PHASE_TIMING
$env:LEAN_CTX_PHASE_TIMING = "1"

function Invoke-LeanCtxDiagnostic {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    $stdoutPath = Join-Path $resolvedOutput "$timestamp-$Name.stdout.log"
    $stderrPath = Join-Path $resolvedOutput "$timestamp-$Name.stderr.log"
    $start = Get-Date
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $process.StartInfo.FileName = "lean-ctx"
    $process.StartInfo.WorkingDirectory = $WorkingDirectory
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true

    foreach ($argument in $Arguments) {
        $process.StartInfo.ArgumentList.Add($argument)
    }

    $stdoutBuilder = [System.Text.StringBuilder]::new()
    $stderrBuilder = [System.Text.StringBuilder]::new()

    try {
        if (-not $process.Start()) {
            throw "Failed to start lean-ctx for diagnostic '$Name'."
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $finished = $process.WaitForExit($TimeoutSeconds * 1000)

        if (-not $finished) {
            try {
                $process.Kill($true)
            } catch {
                # The process may have exited between the timeout and Kill.
            }
            $process.WaitForExit()
            $exitCode = 124
            $status = "TIMED OUT after $TimeoutSeconds seconds (exit code 124)"
        } else {
            $exitCode = $process.ExitCode
            $status = if ($exitCode -eq 0) { "PASS" } else { "FAILED (exit code $exitCode)" }
        }

        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        [System.IO.File]::WriteAllText($stdoutPath, $stdout)
        [System.IO.File]::WriteAllText($stderrPath, $stderr)

        [pscustomobject]@{
            Name = $Name
            Status = $status
            ExitCode = $exitCode
            DurationSeconds = [math]::Round(((Get-Date) - $start).TotalSeconds, 2)
            StdoutLog = $stdoutPath
            StderrLog = $stderrPath
        }
    } finally {
        $process.Dispose()
    }
}

$results = @()
try {
    $version = & lean-ctx --version 2>&1 | Out-String
    $versionExitCode = $LASTEXITCODE

    $results += Invoke-LeanCtxDiagnostic -Name "semantic-search" -WorkingDirectory $resolvedRoot -Arguments @(
        "call", "ctx_search",
        "--project-root", $resolvedRoot,
        "--json", (@{
            action = "semantic"
            query = $Query
            top_k = 3
        } | ConvertTo-Json -Compress)
    )

    $results += Invoke-LeanCtxDiagnostic -Name "compose" -WorkingDirectory $resolvedRoot -Arguments @(
        "call", "ctx_compose",
        "--project-root", $resolvedRoot,
        "--json", (@{
            task = $Task
        } | ConvertTo-Json -Compress)
    )

    $lines = @(
        "LeanCTX semantic-search diagnostics",
        "Timestamp: $(Get-Date -Format o)",
        "LeanCTX version: $($version.Trim())",
        "Version command exit code: $versionExitCode",
        "Project root: $resolvedRoot",
        "Query: $Query",
        "Task: $Task",
        "Phase timing: LEAN_CTX_PHASE_TIMING=1",
        "Timeout per command: $TimeoutSeconds seconds",
        "",
        "Results:"
    )

    foreach ($result in $results) {
        $lines += "- $($result.Name): $($result.Status); duration=$($result.DurationSeconds)s"
        $lines += "  stdout: $($result.StdoutLog)"
        $lines += "  stderr: $($result.StderrLog)"
    }

    $lines += ""
    $lines += "Share the summary and relevant [phase] lines from stderr logs when reporting a bug."
    $lines += "Review logs for sensitive paths or source snippets before sharing them."
    [System.IO.File]::WriteAllLines($summaryPath, $lines)

    Write-Host "Diagnostics finished. Summary: $summaryPath"
    $results | Format-Table Name, Status, DurationSeconds -AutoSize
    Write-Host "Logs are local only; this script does not upload or transmit them."
} finally {
    if ($null -eq $oldPhaseTiming) {
        Remove-Item Env:LEAN_CTX_PHASE_TIMING -ErrorAction SilentlyContinue
    } else {
        $env:LEAN_CTX_PHASE_TIMING = $oldPhaseTiming
    }
}
