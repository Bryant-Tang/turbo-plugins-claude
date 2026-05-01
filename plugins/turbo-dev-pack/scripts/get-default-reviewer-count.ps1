Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$val = $env:TDP_IMPLEMENT_TASK_REVIEWERS
if ([string]::IsNullOrWhiteSpace($val)) { '3' } else { $val }
