param([ValidateSet('Scan','Review')][string]$Mode = 'Scan', [string]$GameDir, [string]$Report, [string]$Baseline, [switch]$Deep)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Show-Header([string]$Title) {
    Write-Host ''
    Write-Host '  +==============================================+' -ForegroundColor DarkCyan
    Write-Host '    MINECRAFT  /  MOD AUDIT' -ForegroundColor Cyan
    Write-Host "    $Title" -ForegroundColor White
    Write-Host '  +==============================================+' -ForegroundColor DarkCyan
}

function Read-ModInfo([string]$Path) {
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($item in @(
            @{Name='fabric.mod.json'; Loader='Fabric'},
            @{Name='quilt.mod.json'; Loader='Quilt'},
            @{Name='META-INF/neoforge.mods.toml'; Loader='NeoForge'},
            @{Name='META-INF/mods.toml'; Loader='Forge'}
        )) {
            $entry = $archive.GetEntry($item.Name)
            if (!$entry) { continue }
            $ids = @()
            if ($entry.Length -le 65536) {
                $reader = [IO.StreamReader]::new($entry.Open())
                try { $metadata = $reader.ReadToEnd() } finally { $reader.Dispose() }
                if ($item.Loader -eq 'Fabric') {
                    $ids = @((ConvertFrom-Json -InputObject $metadata).id)
                } elseif ($item.Loader -eq 'Quilt') {
                    $ids = @((ConvertFrom-Json -InputObject $metadata).quilt_loader.id)
                } else {
                    $ids = @([regex]::Matches($metadata, '(?m)^\s*modId\s*=\s*["'']([a-z0-9_.-]+)["'']') |
                        ForEach-Object { $_.Groups[1].Value })
                }
            }
            return @{loader=$item.Loader; ids=@($ids | Where-Object { $_ -cmatch '^[a-z0-9_.-]{1,128}$' })}
        }
        return @{loader='Unknown'; ids=@()}
    } finally { $archive.Dispose() }
}

function Read-SavedReport([string]$Path) {
    $file = Get-Item -LiteralPath $Path
    if ($file.PSIsContainer -or $file.Length -gt 5MB) { throw 'Expected a JSON report under 5 MB.' }
    $data = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($data.schema -cne 'minecraft-mod-audit-v1' -or !($data.PSObject.Properties['mods'])) {
        throw 'Unrecognized report format.'
    }
    return $data
}

function Show-Comparison([string]$Path, [string]$Reference) {
    $data = Read-SavedReport $Path
    $allowed = @{}
    if ($Reference) {
        foreach ($mod in (Read-SavedReport $Reference).mods) {
            if ($mod.sha256 -match '^[a-f0-9]{64}$') { $allowed[[string]$mod.sha256] = $true }
        }
    }
    Write-Host "Profile mods folder: $($data.modsFolderPresent -eq $true)"
    $rows = foreach ($mod in $data.mods) {
        $status = 'Inventory'
        if ($mod.readError -eq $true -or $mod.sha256 -notmatch '^[a-f0-9]{64}$') {
            $status = 'Read error'
        } elseif ($Reference) {
            $status = 'Outside baseline'
            if ($allowed.ContainsKey([string]$mod.sha256)) { $status = 'Match' }
        }
        [pscustomobject]@{
            Profile = $mod.profile
            File = ([string]$mod.file -replace '[\p{C}]', '?')
            Loader = ([string]$mod.loader -replace '[\p{C}]', '?')
            ModIds = (($mod.ids -join ', ') -replace '[\p{C}]', '?')
            Status = $status
        }
    }
    if ($rows) { $rows | Format-Table -AutoSize -Wrap } else { Write-Host 'No JAR entries.' }
}

function Get-ProfileMods {
    param([string]$Path, [int]$Profile)
    Get-ChildItem -LiteralPath $Path -File -Force -Filter '*.jar' |
        Where-Object { $_.Extension -ieq '.jar' -and !($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
        ForEach-Object {
            $hash = $null
            $info = @{loader='Unknown'; ids=@()}
            $failed = $false
            try {
                $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
                $info = Read-ModInfo $_.FullName
            } catch { $failed = $true }
            [pscustomobject]@{
                profile=$Profile; file=$_.Name; sha256=$hash; loader=$info.loader; ids=@($info.ids); readError=$failed
            }
        }
}

function Show-Globe($Frame, $Done, $Total, $Visited) {
    $w = $Host.UI.RawUI.WindowSize.Width
    $h = $Host.UI.RawUI.WindowSize.Height
    if ($w -lt 38 -or $h -lt 12) { return }
    $r = [Math]::Min([int](($w - 6)/4), [int](($h - 8)/2))
    $left = [int](($w - 4*$r - 2)/2)
    $host.UI.RawUI.CursorPosition = [Management.Automation.Host.Coordinates]::new(0,$Host.UI.RawUI.WindowPosition.Y)
    Write-Host (' ' * [Math]::Max(0,[int](($w - 17)/2)) + 'MINECRAFT MOD AUDIT') -ForegroundColor White
    $map = @(
        @(-105,48,40,24), @(-80,22,16,12), @(-61,-15,21,31), @(-42,70,18,13),
        @(15,50,32,14), @(20,4,26,34), @(85,49,68,26), @(103,17,32,15), @(135,-25,24,15)
    )
    for ($row = -$r; $row -le $r; $row++) {
        $y = -$row/$r
        $lat = [Math]::Asin($y)*180/[Math]::PI
        $line = [Text.StringBuilder]::new()
        for ($col = -2*$r; $col -le 2*$r; $col++) {
            $x = $col/(2*$r)
            $d = $x*$x + $y*$y
            if ($d -gt 1) { [void]$line.Append(' '); continue }
            $lon = [Math]::Atan2($x,[Math]::Sqrt(1-$d))*180/[Math]::PI + $Frame*8
            $glyph = '.'
            if ($lat -lt -70) { $glyph = '#' }
            foreach ($area in $map) {
                $dx = ((($lon-$area[0]+180)%360+360)%360-180)/$area[2]
                $dy = ($lat-$area[1])/$area[3]
                if ($dx*$dx + $dy*$dy -lt 1) { $glyph = '#'; break }
            }
            [void]$line.Append($glyph)
        }
        Write-Host ((' '*$left + $line.ToString()).PadRight($w-1)) -ForegroundColor Cyan
    }
    $size = [Math]::Min(50,$w-8)
    $fill = [int][Math]::Floor($size*$Done/$Total)
    $bar = '[' + '='*$fill + '-'*($size-$fill) + ']'
    Write-Host (' '*[int](($w-$bar.Length-1)/2) + $bar) -ForegroundColor Green
    Write-Host ("Disks: $Done/$Total   Folders: $Visited").PadRight($w-1)
}

function Find-DeepMods([string[]]$Roots) {
    $state = [hashtable]::Synchronized(@{done=0; visited=0; denied=0; profiles=0})
    $worker = [powershell]::Create()
    $null = $worker.AddScript(('function Read-ModInfo {' + (Get-Command Read-ModInfo).Definition + '}'))
    $null = $worker.AddScript(('function Get-ProfileMods {' + (Get-Command Get-ProfileMods).Definition + '}'))
    $walk = {
        param($Roots, $State)
        $ErrorActionPreference = 'Stop'
        foreach ($root in $Roots) {
            $stack = [Collections.Generic.Stack[string]]::new()
            $stack.Push($root)
            while ($stack.Count) {
                $path = $stack.Pop()
                $State.visited++
                try { $children = [IO.DirectoryInfo]::new($path).GetDirectories() }
                catch { $State.denied++; continue }
                foreach ($dir in $children) {
                    if ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                    $stack.Push($dir.FullName)
                    if ($dir.Name -ine 'mods') { continue }
                    if (
                        ![IO.Directory]::Exists([IO.Path]::Combine($path,'versions')) -and
                        ![IO.File]::Exists([IO.Path]::Combine($path,'options.txt')) -and
                        ![IO.File]::Exists([IO.Path]::Combine($path,'logs','latest.log'))
                    ) { continue }
                    $State.profiles++
                    try { Get-ProfileMods $dir.FullName $State.profiles }
                    catch { $State.denied++ }
                }
            }
            $State.done++
        }
    }
    $null = $worker.AddScript($walk.ToString()).AddArgument($Roots).AddArgument($state)
    $draw = ![Console]::IsOutputRedirected -and $Host.Name -eq 'ConsoleHost'
    $frame = 0
    try {
        if ($draw) { Clear-Host }
        $task = $worker.BeginInvoke()
        while (!$task.IsCompleted) {
            if ($draw) { Show-Globe ($frame++) $state.done $Roots.Count $state.visited }
            Start-Sleep -Milliseconds 180
        }
        $results = $worker.EndInvoke($task)
        if ($worker.Streams.Error.Count) { throw $worker.Streams.Error[0] }
        if ($draw) { Show-Globe $frame $state.done $Roots.Count $state.visited }
        $results
    } finally { $worker.Dispose() }
    $script:deepStats = @{disks=$state.done; profiles=$state.profiles; unreadableFolders=$state.denied}
    Write-Host "Profiles: $($state.profiles). Unreadable folders: $($state.denied)."
}

if ($Mode -eq 'Review') {
    Show-Header 'MODERATOR CONSOLE'
    if ($Report) { Show-Comparison $Report $Baseline; exit }
    while ($true) {
        Write-Host ''
        Write-Host '  [1] Open report    [2] Set baseline    [0] Exit' -ForegroundColor Cyan
        try {
            switch (Read-Host 'Choice') {
                '1' { Show-Comparison ((Read-Host 'Report JSON path').Trim('"')) $Baseline }
                '2' {
                    $path = (Read-Host 'Trusted profile report JSON path (empty clears)').Trim('"')
                    if ($path) { $null = Read-SavedReport $path }
                    $Baseline = $path
                }
                '0' { return }
            }
        } catch { Write-Host $_.Exception.Message -ForegroundColor Yellow }
    }
}

Show-Header 'PLAYER CHECK'
$deepStats = $null
if ($Deep) {
    if ($GameDir) { throw 'Choose either Deep or GameDir.' }
    $roots = @([IO.DriveInfo]::GetDrives() |
        Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } |
        ForEach-Object { $_.RootDirectory.FullName })
    if (!$roots.Count) { throw 'No ready local fixed disks.' }
    Write-Host ('Local fixed disks: ' + ($roots -join ', ')) -ForegroundColor Yellow
    Write-Host 'Reads directory names and JAR files under detected Minecraft Java mods folders.'
    Write-Host 'The local JSON contains mod details, profile numbers and aggregate counts.'
    if ((Read-Host 'Type YES to scan and save a local report') -cne 'YES') { return }
    $mods = @(Find-DeepMods $roots)
    $modsFolder = $deepStats.profiles -gt 0
} else {
    if (!$GameDir) {
        $default = Join-Path $env:APPDATA '.minecraft'
        $GameDir = (Read-Host "Open instance folder [$default]").Trim('"')
        if (!$GameDir) { $GameDir = $default }
    }
    $profile = Get-Item -LiteralPath $GameDir
    if (!$profile.PSIsContainer -or ($profile.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Choose a regular Minecraft profile directory.'
    }
    $modsPath = Join-Path $profile.FullName 'mods'
    $modsFolder = Get-Item -LiteralPath $modsPath -Force -ErrorAction SilentlyContinue
    if ($modsFolder -and (!$modsFolder.PSIsContainer -or ($modsFolder.Attributes -band [IO.FileAttributes]::ReparsePoint))) {
        throw 'Expected mods to be a regular directory.'
    }
    Write-Host "Read only: $modsPath" -ForegroundColor Yellow
    Write-Host 'The local JSON contains JAR names, mod IDs, loaders, SHA-256 and scan time.'
    if ((Read-Host 'Type YES to scan and save a local report') -cne 'YES') { return }

    $mods = @(if ($modsFolder) { Get-ProfileMods $modsPath 1 })
}

if (!$Report) { $Report = Join-Path (Get-Location).Path ("mod-report-{0}.json" -f [guid]::NewGuid().ToString('N')) }
$data = [ordered]@{
    schema='minecraft-mod-audit-v1'
    scannedUtc=[datetime]::UtcNow.ToString('o')
    modsFolderPresent=[bool]$modsFolder
    deepScan=$deepStats
    mods=$mods
}
$data | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $Report -Encoding UTF8 -NoClobber
Show-Comparison $Report $null
Write-Host "Saved: $Report" -ForegroundColor Green
Write-Host 'Review the JSON before sharing it with a moderator.'

