#Requires -Version 7
<#
Start-ClaudeProject.ps1 — pick a Claude Code project from a list and open it.
A chosen project opens in a NEW Windows Terminal tab (in the same window) and the
chooser stays open, so you can start several projects one after another. Each
project gets its own color the first time it is opened (stored in .tab-colors.json
in the projects root); the tab and the name in the list both use that color.

Enter = most recent project, number = open that project,
n = new project (scaffolds a PROGRESS.md session-notes file), q = quit.
Type any other word to filter the list on project name (several words = all must match);
  * shows the full list again. Numbers always refer to the list as shown.
Append ! to any choice (e.g. 3!, n!, or just !) to launch in UNATTENDED mode
  (--dangerously-skip-permissions) for nightly sessions that must run without prompts.
Extra arguments are passed through to claude (e.g. --resume, --model ...).

The projects root is read from the CLAUDE_PROJECTS_ROOT environment variable;
without it, ~\Claude\projects is used. Handy as a shortcut or profile alias:
  pwsh -NoExit -File Start-ClaudeProject.ps1
The new tab runs this same script with -Launch, which is why the param block
below exists — you never type -Launch yourself.
#>
param(
    [string]$Launch,
    [switch]$Unattended,
    [Parameter(ValueFromRemainingArguments)][string[]]$ClaudeArgs
)

$projectsRoot = if ($env:CLAUDE_PROJECTS_ROOT) { $env:CLAUDE_PROJECTS_ROOT } else { Join-Path $HOME 'Claude\projects' }
if (-not (Test-Path $projectsRoot)) {
    Write-Host "Projects folder not found: $projectsRoot" -ForegroundColor Red
    Write-Host "Create it, or point the CLAUDE_PROJECTS_ROOT environment variable at your projects folder." -ForegroundColor Red
    return
}

# ---- Launch mode: this is the half that runs inside the new tab. ----
if ($Launch) {
    Set-Location $Launch
    $extra = @($ClaudeArgs | Where-Object { $_ })
    if ($Unattended) {
        Write-Host ""
        Write-Host "  ============================================================" -ForegroundColor Red
        Write-Host "   UNATTENDED MODE — running with --dangerously-skip-permissions" -ForegroundColor Red
        Write-Host "   Claude will act without asking. Use only for trusted nightly work." -ForegroundColor Red
        Write-Host "  ============================================================" -ForegroundColor Red
        Write-Host "   Project: $Launch" -ForegroundColor DarkGray
        Write-Host "   Ctrl+C now to abort — starting in 5s..." -ForegroundColor Yellow
        Start-Sleep -Seconds 5
        $extra += '--dangerously-skip-permissions'
    }
    # Windows Terminal keeps --title/--suppressApplicationTitle only as overrides on the
    # tab and drops them when it rebuilds its tabs (screen lock, docking, theme signal;
    # microsoft/terminal #15732). After that Claude's own title (the "* summary" text)
    # shows up. So: tell Claude Code never to touch the title, and set the console
    # title to the project name ourselves, so a rebuilt tab falls back to that name.
    $env:CLAUDE_CODE_DISABLE_TERMINAL_TITLE = '1'
    $Host.UI.RawUI.WindowTitle = Split-Path $Launch -Leaf
    claude @extra
    return
}

# ---- Chooser mode from here on. ----

# Every project gets a fixed color the first time it is opened. The table lives in
# .tab-colors.json in the projects root (OneDrive, so it travels along) and is only
# ever appended to — a project keeps its color forever.
$chooserScript = $PSCommandPath

$colorFile = Join-Path $projectsRoot '.tab-colors.json'
$colors = @{}
if (Test-Path $colorFile) {
    (Get-Content $colorFile -Raw | ConvertFrom-Json).PSObject.Properties |
        ForEach-Object { $colors[$_.Name] = $_.Value }
}

function Convert-HslToHex([double]$H, [double]$S, [double]$L) {
    $c = (1 - [math]::Abs(2 * $L - 1)) * $S
    $x = $c * (1 - [math]::Abs((($H / 60) % 2) - 1))
    $m = $L - $c / 2
    switch ([int][math]::Floor($H / 60) % 6) {
        0 { $r, $g, $b = $c, $x, 0.0 }
        1 { $r, $g, $b = $x, $c, 0.0 }
        2 { $r, $g, $b = 0.0, $c, $x }
        3 { $r, $g, $b = 0.0, $x, $c }
        4 { $r, $g, $b = $x, 0.0, $c }
        5 { $r, $g, $b = $c, 0.0, $x }
    }
    '#{0:x2}{1:x2}{2:x2}' -f [int](($r + $m) * 255), [int](($g + $m) * 255), [int](($b + $m) * 255)
}

function Get-ProjectColor([string]$name) {
    if (-not $colors.ContainsKey($name)) {
        # 137.5 degrees further around the color circle per new project: every
        # next color sits far away from all the earlier ones.
        $hue = ($colors.Count * 137.5) % 360
        $colors[$name] = Convert-HslToHex $hue 0.65 0.50
        $colors | ConvertTo-Json | Set-Content $colorFile -Encoding utf8
    }
    $colors[$name]
}

# Opens the project in a new tab of the same Windows Terminal window. The tab runs
# this script again with -Launch, so no quoted -Command string is needed. wt reads
# a bare ; as "next wt command", hence the \; escaping.
function Open-ProjectTab([string]$path, [string]$name, [bool]$unatt, [string[]]$extra) {
    $hex = Get-ProjectColor $name
    $wtArgs = @(
        '-w', '0', 'new-tab',
        '--title', ($name -replace ';', '\;'), '--suppressApplicationTitle',
        '--tabColor', $hex,
        '-d', ($path -replace ';', '\;'),
        'pwsh', '-NoExit', '-File', $chooserScript, '-Launch', ($path -replace ';', '\;')
    )
    if ($unatt) { $wtArgs += '-Unattended' }
    foreach ($a in @($extra | Where-Object { $_ })) { $wtArgs += ($a -replace ';', '\;') }
    wt @wtArgs
    Write-Host "Opened $name in a new tab." -ForegroundColor Green
}

# Folders named C--Users... are Claude Code housekeeping folders, not projects.
$dirs = Get-ChildItem $projectsRoot -Directory |
    Where-Object { $_.Name -notmatch '^C--Users' } |
    Sort-Object LastWriteTime -Descending

# $shown is the list as last printed — every number the user types refers to it.
$shown = @($dirs)
$filter = ''
$unattended = $false
$esc = [char]27

while ($true) {
    Write-Host ""
    $title = "Claude projects  ($projectsRoot)"
    if ($filter) { $title += "  — filter: $filter" }
    Write-Host $title -ForegroundColor Cyan
    Write-Host "  (a * in front of a name = that project has PROGRESS.md; a colored name = has a tab color)" -ForegroundColor DarkGray
    $i = 1
    foreach ($d in $shown) {
        $marker = if (Test-Path (Join-Path $d.FullName 'PROGRESS.md')) { '*' } else { ' ' }
        $name = $d.Name
        if ($colors.ContainsKey($name)) {
            $hex = $colors[$name]
            $cr = [Convert]::ToInt32($hex.Substring(1, 2), 16)
            $cg = [Convert]::ToInt32($hex.Substring(3, 2), 16)
            $cb = [Convert]::ToInt32($hex.Substring(5, 2), 16)
            $name = "$esc[38;2;$cr;$cg;${cb}m$name$esc[0m"
        }
        Write-Host ("{0,3}. {1} {2}  ({3:yyyy-MM-dd})" -f $i, $marker, $name, $d.LastWriteTime)
        $i++
    }
    Write-Host ""
    Write-Host "Enter = 1 (most recent) | number = open in a new tab | n = new project | q = quit" -ForegroundColor DarkGray
    Write-Host "Type a word to filter on project name | type * to show all projects again" -ForegroundColor DarkGray
    Write-Host "Add ! for unattended mode (skips permission prompts) — e.g. 3! or n!" -ForegroundColor DarkYellow
    $entry = (Read-Host "Project").Trim()

    # An appended ! opts this launch into unattended (skip-permissions) mode.
    # Only strip it when what remains is a real choice, so a search word keeps its !.
    $stripped = ($entry -replace '!', '').Trim()
    if ($entry -match '!' -and ($stripped -eq '' -or $stripped -eq 'n' -or $stripped -match '^\d+$')) {
        $unattended = $true
        $entry = $stripped
    }

    if ($entry -eq '*') { $shown = @($dirs); $filter = ''; $unattended = $false; continue }

    if ($entry -eq 'q') { return }

    if ($entry -eq 'n') {
        $name = Read-Host "New project name"
        if ([string]::IsNullOrWhiteSpace($name)) { $unattended = $false; continue }
        $target = Join-Path $projectsRoot $name
        if (-not (Test-Path $target)) {
            New-Item -ItemType Directory -Path $target | Out-Null
            @"
# PROGRESS — $name

## Current focus
New project, nothing done yet.

## Done this session
-

## Next up
-

## Open questions / blockers
-

## In-flight work
- None.
"@ | Set-Content (Join-Path $target 'PROGRESS.md') -Encoding utf8
            Write-Host "Created $target with PROGRESS.md scaffold." -ForegroundColor Green
        }
        Open-ProjectTab $target $name $unattended $ClaudeArgs
    }
    elseif ($entry -eq '' -or $entry -match '^\d+$') {
        # A number out of range is easy to type right after the list renumbered,
        # so say so and stay in the list instead of dropping out of the script.
        if ($entry -match '^\d+$' -and ([int]$entry -lt 1 -or [int]$entry -gt $shown.Count)) {
            Write-Host "There is no $entry in this list (1-$($shown.Count))." -ForegroundColor Red
            $unattended = $false
            continue
        }
        $idx = if ($entry -eq '') { 1 } else { [int]$entry }
        Open-ProjectTab $shown[$idx - 1].FullName $shown[$idx - 1].Name $unattended $ClaudeArgs
    }
    else {
        # A ! only switches on unattended mode next to a real choice; on a search word it is
        # dropped, with a note, rather than silently arming the mode or killing the search.
        if ($entry -match '!') {
            Write-Host "Ignoring the ! — add it to the choice you launch with (e.g. 2!)." -ForegroundColor DarkGray
            $entry = ($entry -replace '!', '').Trim()
            if ($entry -eq '') { continue }
        }

        $words = $entry -split '\s+' | Where-Object { $_ }
        $matched = $dirs | Where-Object {
            $name = $_.Name
            -not ($words | Where-Object { $name.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -lt 0 })
        }
        if (-not $matched) {
            Write-Host "No project name contains: $entry" -ForegroundColor Red
            continue
        }
        $shown = @($matched)
        $filter = $entry
        $unattended = $false
        continue
    }

    # A tab was just opened: re-read the list (the opened or new project moves up)
    # and start clean, without filter or armed unattended mode.
    $dirs = Get-ChildItem $projectsRoot -Directory |
        Where-Object { $_.Name -notmatch '^C--Users' } |
        Sort-Object LastWriteTime -Descending
    $shown = @($dirs)
    $filter = ''
    $unattended = $false
}
