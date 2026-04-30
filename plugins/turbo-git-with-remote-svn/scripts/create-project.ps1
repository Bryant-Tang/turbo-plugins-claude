param(
    [string]$SvnUrl = '',
    [string]$Path = '',
    [string]$Name = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Utf8NoBom {
    param([string]$FilePath, [string]$Content)
    [System.IO.File]::WriteAllText($FilePath, $Content, (New-Object System.Text.UTF8Encoding $false))
}

try {
    if ([string]::IsNullOrWhiteSpace($SvnUrl)) {
        throw 'Missing required argument: -SvnUrl <url>'
    }

    $resolvedPath = if ([string]::IsNullOrWhiteSpace($Path)) { (Get-Location).Path } else { [System.IO.Path]::GetFullPath($Path) }
    $resolvedName = if ([string]::IsNullOrWhiteSpace($Name)) { [System.IO.Path]::GetFileName($resolvedPath.TrimEnd('/\')) } else { $Name }

    if ([string]::IsNullOrWhiteSpace($resolvedName)) {
        throw 'Could not determine project name. Provide -Name explicitly.'
    }

    $projDir = Join-Path $resolvedPath $resolvedName
    $worktreesDir = Join-Path $resolvedPath "$resolvedName.worktrees"
    $remotemainDir = Join-Path $worktreesDir 'remote-main'
    $workspaceFile = Join-Path $resolvedPath "$resolvedName.code-workspace"

    if (Test-Path -LiteralPath $projDir) {
        $items = Get-ChildItem -LiteralPath $projDir -Force -ErrorAction SilentlyContinue
        if ($items) { throw "Directory already exists and is not empty: $projDir" }
    }

    Write-Output "Creating project '$resolvedName' at '$resolvedPath'..."

    New-Item -ItemType Directory -Force -Path $projDir | Out-Null
    New-Item -ItemType Directory -Force -Path $worktreesDir | Out-Null

    & git -C $projDir -c init.defaultBranch=main init
    if ($LASTEXITCODE -ne 0) { throw 'git init failed' }

    # Copy git user identity from current context into the new repo (avoids requiring global config)
    $gitUserName  = (& git config user.name  2>$null | Out-String).Trim()
    $gitUserEmail = (& git config user.email 2>$null | Out-String).Trim()
    if ($gitUserName)  { & git -C $projDir config user.name  $gitUserName }
    if ($gitUserEmail) { & git -C $projDir config user.email $gitUserEmail }

    Write-Utf8NoBom -FilePath (Join-Path $projDir '.gitignore') -Content ".svn/**/*`n"

    & git -C $projDir add .gitignore
    if ($LASTEXITCODE -ne 0) { throw 'git add failed' }
    & git -C $projDir commit -m 'init'
    if ($LASTEXITCODE -ne 0) { throw 'git commit failed' }

    & git -C $projDir branch 'remote/main'
    if ($LASTEXITCODE -ne 0) { throw 'git branch remote/main failed' }

    & git -C $projDir worktree add $remotemainDir 'remote/main'
    if ($LASTEXITCODE -ne 0) { throw 'git worktree add failed' }

    # .gitignore is already inherited from main's init commit; no separate commit needed

    Write-Output "Running: svn checkout $SvnUrl $remotemainDir"
    & svn checkout $SvnUrl $remotemainDir
    if ($LASTEXITCODE -ne 0) { throw 'svn checkout failed' }

    # Tell SVN to ignore git metadata files so they are never accidentally committed
    Push-Location $remotemainDir
    try {
        & svn propset svn:ignore ".git`n.gitignore" '.'
        if ($LASTEXITCODE -ne 0) { throw 'svn propset svn:ignore failed' }
        & svn commit -m 'svn:ignore git metadata'
        if ($LASTEXITCODE -ne 0) { throw 'svn commit svn:ignore failed' }
    } finally {
        Pop-Location
    }

    $workspaceJson = [ordered]@{
        folders  = @(
            [ordered]@{ name = 'main'; path = $resolvedName }
            [ordered]@{ name = 'remote-main'; path = "$resolvedName.worktrees/remote-main" }
        )
        settings = [ordered]@{}
    } | ConvertTo-Json -Depth 10
    Write-Utf8NoBom -FilePath $workspaceFile -Content $workspaceJson

    Write-Output ""
    Write-Output "Project '$resolvedName' created successfully."
    Write-Output "  Main worktree : $projDir"
    Write-Output "  SVN worktree  : $remotemainDir"
    Write-Output "  Workspace     : $workspaceFile"
    Write-Output ""
    Write-Output "Next step: run '/tgs:pull-from-svn --branch main' to commit the SVN files into"
    Write-Output "  remote/main and merge them into main."
    Write-Output ""
    Write-Output "Recommended: open Claude Code in '$projDir' and run /tgs:setup to configure"
    Write-Output "  tgs environment variable defaults for that working directory."
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
