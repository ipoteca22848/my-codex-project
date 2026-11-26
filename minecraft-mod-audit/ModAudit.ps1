param([ValidateSet('Scan','Review')][string]$Mode = 'Scan', [string]$GameDir, [string]$Report, [string]$Baseline)
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
            File = ([string]$mod.file -replace '[\p{C}]', '?')
            Loader = ([string]$mod.loader -replace '[\p{C}]', '?')
            ModIds = (($mod.ids -join ', ') -replace '[\p{C}]', '?')
            Status = $status
        }
    }
    if ($rows) { $rows | Format-Table -AutoSize -Wrap } else { Write-Host 'No JAR entries.' }
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

$mods = @(
    if ($modsFolder) {
        Get-ChildItem -LiteralPath $modsPath -File -Force -Filter '*.jar' |
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
                    file=$_.Name; sha256=$hash; loader=$info.loader; ids=@($info.ids); readError=$failed
                }
            }
    }
)

if (!$Report) { $Report = Join-Path (Get-Location).Path ("mod-report-{0}.json" -f [guid]::NewGuid().ToString('N')) }
$data = [ordered]@{
    schema='minecraft-mod-audit-v1'
    scannedUtc=[datetime]::UtcNow.ToString('o')
    modsFolderPresent=[bool]$modsFolder
    mods=$mods
}
$data | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $Report -Encoding UTF8 -NoClobber
Show-Comparison $Report $null
Write-Host "Saved: $Report" -ForegroundColor Green
Write-Host 'Review the JSON before sharing it with a moderator.'
