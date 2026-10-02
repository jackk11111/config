param(
    [string]$Super = "$env:USERPROFILE\Downloads\TicWatch_Wear7_DIAG3_FINAL\FlashKit\super_WEAR7_V11_DIAG3_FINAL.img",
    [string]$Adb = "adb.exe",
    [string]$Serial = ""
)

$ErrorActionPreference = 'Stop'

$PatchUrl = 'https://raw.githubusercontent.com/jackk11111/config/wear7-diag4-init-bisect-20261002/wear7/diag4/DIAG4_PATCH.json'
$ExpectedSource = '75c8d716e0f243cfe309d9fca29aba0253f524bb70d93959dcd5d4fba0dc3329'
$ExpectedTarget = '5f15ab8fc99d7cf80b7edc1389a524549c891b700f228d84554ee8847c3a42ec'
$ExpectedRaw    = '24b607b5f7f7b59a7a73bd849c2fae355c5d738a2e47ffd774d3ae5388c08ac7'
$ExpectedRawBlocks = @(888867,888869,888870,903992,904067,904082)
$BlockSize = 4096

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Invoke-AdbText([string[]]$Args) {
    $out = & $Adb @Args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "ADB_FAILED rc=$LASTEXITCODE args=$($Args -join ' ') output=$($out -join ' ')"
    }
    return (($out | ForEach-Object { [string]$_ }) -join "`n").Trim()
}

function Read-Exact([System.IO.Stream]$Stream, [int]$Count) {
    $buf = New-Object byte[] $Count
    $off = 0
    while ($off -lt $Count) {
        $n = $Stream.Read($buf, $off, $Count - $off)
        if ($n -le 0) { throw "UNEXPECTED_EOF wanted=$Count got=$off" }
        $off += $n
    }
    return $buf
}

Write-Host '===== WEAR7 DIAG4 LIVE RECOVERY PATCH ====='
Write-Host "SOURCE_SPARSE=$Super"

if (-not (Test-Path -LiteralPath $Super -PathType Leaf)) {
    throw "SUPER_NOT_FOUND=$Super"
}

$sourceHash = Get-Sha256 $Super
Write-Host "SOURCE_SPARSE_SHA256=$sourceHash"
if ($sourceHash -ne $ExpectedSource) {
    throw "SOURCE_SHA_MISMATCH expected=$ExpectedSource got=$sourceHash"
}

$Patch = Invoke-RestMethod -Uri $PatchUrl -Headers @{ 'Cache-Control' = 'no-cache' }
if ([string]$Patch.source_sparse_sha256 -ne $ExpectedSource) { throw 'PATCH_METADATA_SOURCE_SHA_MISMATCH' }
if ([string]$Patch.target_sparse_sha256 -ne $ExpectedTarget) { throw 'PATCH_METADATA_TARGET_SHA_MISMATCH' }
if ([string]$Patch.target_raw_sha256 -ne $ExpectedRaw) { throw 'PATCH_METADATA_RAW_SHA_MISMATCH' }
if ([int]$Patch.changed_raw_blocks -ne 6) { throw "PATCH_METADATA_BLOCK_COUNT_MISMATCH=$($Patch.changed_raw_blocks)" }
if (@($Patch.records).Count -ne 31) { throw "PATCH_METADATA_RECORD_COUNT_MISMATCH=$(@($Patch.records).Count)" }

$wanted = @{}
foreach ($b in $ExpectedRawBlocks) { $wanted[[string][Int64]$b] = $true }
foreach ($r in @($Patch.records)) {
    $k = [string][Int64]$r.raw_block
    if (-not $wanted.ContainsKey($k)) { throw "UNEXPECTED_PATCH_RAW_BLOCK=$k" }
}

# Parse the exact DIAG3 Android sparse image and map the six changed expanded RAW blocks
# back to their payload positions. No simg2img/lpunpack/build is needed.
$map = @{}
$fs = [System.IO.File]::Open($Super, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
try {
    $hdr = Read-Exact $fs 28
    $magic = [BitConverter]::ToUInt32($hdr,0)
    $fileHdrSz = [BitConverter]::ToUInt16($hdr,8)
    $chunkHdrSz = [BitConverter]::ToUInt16($hdr,10)
    $blkSz = [BitConverter]::ToUInt32($hdr,12)
    $totalBlks = [BitConverter]::ToUInt32($hdr,16)
    $totalChunks = [BitConverter]::ToUInt32($hdr,20)
    if ($magic -ne 0xED26FF3A -or $blkSz -ne $BlockSize -or $fileHdrSz -lt 28 -or $chunkHdrSz -lt 12) {
        throw "UNEXPECTED_SPARSE_HEADER magic=$('{0:x8}' -f $magic) block=$blkSz filehdr=$fileHdrSz chunkhdr=$chunkHdrSz"
    }
    if ($fileHdrSz -gt 28) { [void]$fs.Seek($fileHdrSz - 28, [System.IO.SeekOrigin]::Current) }
    [Int64]$rawBlock = 0
    for ($ci=0; $ci -lt $totalChunks; $ci++) {
        $ch = Read-Exact $fs $chunkHdrSz
        $typ = [BitConverter]::ToUInt16($ch,0)
        [Int64]$count = [BitConverter]::ToUInt32($ch,4)
        [Int64]$payload = $fs.Position
        foreach ($b in $ExpectedRawBlocks) {
            [Int64]$bb = $b
            if ($bb -ge $rawBlock -and $bb -lt ($rawBlock + $count)) {
                if ($typ -ne 0xCAC1) { throw "CHANGED_BLOCK_NOT_RAW block=$bb type=$('{0:x4}' -f $typ)" }
                $map[[string]$bb] = $payload + (($bb - $rawBlock) * $BlockSize)
            }
        }
        switch ($typ) {
            0xCAC1 { [void]$fs.Seek($count * $BlockSize, [System.IO.SeekOrigin]::Current) }
            0xCAC2 { [void]$fs.Seek(4, [System.IO.SeekOrigin]::Current) }
            0xCAC3 { }
            0xCAC4 { [void]$fs.Seek(4, [System.IO.SeekOrigin]::Current) }
            default { throw "UNKNOWN_SPARSE_CHUNK=$('{0:x4}' -f $typ)" }
        }
        $rawBlock += $count
    }
    if ($rawBlock -ne $totalBlks) { throw "SPARSE_TOTAL_BLOCK_MISMATCH expected=$totalBlks got=$rawBlock" }
    if ($map.Count -ne 6) { throw "SPARSE_MAP_INCOMPLETE count=$($map.Count)" }
} finally {
    $fs.Dispose()
}

$tmp = Join-Path $env:TEMP ("wear7_diag4_live_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$blockInfo = @{}

try {
    $fs = [System.IO.File]::Open($Super, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        foreach ($b in $ExpectedRawBlocks) {
            $k = [string][Int64]$b
            [void]$fs.Seek([Int64]$map[$k], [System.IO.SeekOrigin]::Begin)
            [byte[]]$src = Read-Exact $fs $BlockSize
            [byte[]]$tgt = New-Object byte[] $BlockSize
            [Array]::Copy($src,$tgt,$BlockSize)

            foreach ($r in @($Patch.records | Where-Object { [Int64]$_.raw_block -eq [Int64]$b })) {
                [Int64]$within = [Int64]$r.sparse_offset - [Int64]$map[$k]
                [byte[]]$old = [Convert]::FromBase64String([string]$r.old_b64)
                [byte[]]$new = [Convert]::FromBase64String([string]$r.new_b64)
                if ($within -lt 0 -or ($within + $old.Length) -gt $BlockSize) { throw "PATCH_RANGE_INVALID block=$b within=$within" }
                if ($old.Length -ne [int]$r.length -or $new.Length -ne [int]$r.length) { throw "PATCH_LENGTH_INVALID block=$b" }
                [byte[]]$got = New-Object byte[] $old.Length
                [Array]::Copy($tgt,[int]$within,$got,0,$old.Length)
                if ([Convert]::ToBase64String($got) -ne [string]$r.old_b64) { throw "PATCH_SOURCE_BYTES_MISMATCH block=$b within=$within" }
                [Array]::Copy($new,0,$tgt,[int]$within,$new.Length)
            }

            $srcPath = Join-Path $tmp ("src_$b.bin")
            $tgtPath = Join-Path $tmp ("tgt_$b.bin")
            [System.IO.File]::WriteAllBytes($srcPath,$src)
            [System.IO.File]::WriteAllBytes($tgtPath,$tgt)
            $blockInfo[$k] = [pscustomobject]@{
                Block=[Int64]$b
                SourcePath=$srcPath
                TargetPath=$tgtPath
                SourceSha=(Get-Sha256 $srcPath)
                TargetSha=(Get-Sha256 $tgtPath)
            }
        }
    } finally {
        $fs.Dispose()
    }

    Write-Host 'LOCAL_RAW_BLOCK_DERIVATION=PASS'
    foreach ($b in $ExpectedRawBlocks) {
        $x=$blockInfo[[string][Int64]$b]
        Write-Host "BLOCK=$($x.Block) SOURCE_SHA256=$($x.SourceSha) TARGET_SHA256=$($x.TargetSha)"
    }

    if ([string]::IsNullOrWhiteSpace($Serial)) {
        $lines = & $Adb devices 2>&1
        if ($LASTEXITCODE -ne 0) { throw "ADB_DEVICES_FAILED=$($lines -join ' ')" }
        $candidates = @()
        foreach ($line in $lines) {
            if ([string]$line -match '^([^\s]+)\s+recovery(?:\s|$)') { $candidates += $Matches[1] }
        }
        if ($candidates.Count -ne 1) { throw "RECOVERY_ADB_DEVICE_COUNT=$($candidates.Count) devices=$($lines -join ' | ')" }
        $Serial = $candidates[0]
    }
    Write-Host "ADB_SERIAL=$Serial"

    $id = Invoke-AdbText @('-s',$Serial,'shell','id')
    if ($id -notmatch 'uid=0\(root\)') { throw "RECOVERY_NOT_ROOT=$id" }
    Write-Host "RECOVERY_ID=$id"

    $superDev = Invoke-AdbText @('-s',$Serial,'shell',"P=`$(readlink -f /dev/block/by-name/super 2>/dev/null); [ -b \"`$P\" ] || P=`$(readlink -f /dev/block/bootdevice/by-name/super 2>/dev/null); [ -b \"`$P\" ] || exit 9; echo \"`$P\"")
    $superDev = ($superDev -split "`n")[-1].Trim()
    if ([string]::IsNullOrWhiteSpace($superDev)) { throw 'LIVE_SUPER_NOT_FOUND' }
    Write-Host "LIVE_SUPER=$superDev"

    $remote = '/tmp/wear7_diag4_live'
    Invoke-AdbText @('-s',$Serial,'shell',"rm -rf $remote; mkdir -p $remote") | Out-Null

    foreach ($b in $ExpectedRawBlocks) {
        $x=$blockInfo[[string][Int64]$b]
        $rSrc="$remote/src_$b.bin"
        $rTgt="$remote/tgt_$b.bin"
        Invoke-AdbText @('-s',$Serial,'push',$x.SourcePath,$rSrc) | Out-Null
        Invoke-AdbText @('-s',$Serial,'push',$x.TargetPath,$rTgt) | Out-Null
    }

    # First decisive gate: all six live raw blocks must be byte-identical to exact DIAG3.
    foreach ($b in $ExpectedRawBlocks) {
        $x=$blockInfo[[string][Int64]$b]
        $got = Invoke-AdbText @('-s',$Serial,'shell',"dd if='$superDev' of='$remote/live_$b.bin' bs=4096 skip=$b count=1 2>/dev/null; sha256sum '$remote/live_$b.bin' | awk '{print `$1}'")
        $got = ($got -split "`n")[-1].Trim().ToLowerInvariant()
        Write-Host "LIVE_SOURCE_BLOCK=$b SHA256=$got"
        if ($got -ne $x.SourceSha) { throw "LIVE_SOURCE_BLOCK_MISMATCH block=$b expected=$($x.SourceSha) got=$got" }
    }
    Write-Host 'LIVE_DIAG3_SOURCE_BLOCKS=PASS'

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backup = "/metadata/vold/diag4-live-backup-$stamp"
    Invoke-AdbText @('-s',$Serial,'shell',"mkdir -p '$backup'; chmod 0700 '$backup'; chmod 0700 /metadata/vold/d/04 /metadata/vold/d/12 /metadata/vold/d/17 2>/dev/null || true") | Out-Null

    foreach ($b in $ExpectedRawBlocks) {
        Invoke-AdbText @('-s',$Serial,'shell',"dd if='$superDev' of='$backup/block_$b.bin' bs=4096 skip=$b count=1 2>/dev/null; sync") | Out-Null
    }
    Write-Host "LIVE_BACKUP=$backup"

    $writeStarted=$false
    try {
        $writeStarted=$true
        foreach ($b in $ExpectedRawBlocks) {
            Invoke-AdbText @('-s',$Serial,'shell',"dd if='$remote/tgt_$b.bin' of='$superDev' bs=4096 seek=$b count=1 conv=notrunc 2>/dev/null") | Out-Null
        }
        Invoke-AdbText @('-s',$Serial,'shell','sync') | Out-Null

        foreach ($b in $ExpectedRawBlocks) {
            $x=$blockInfo[[string][Int64]$b]
            $got = Invoke-AdbText @('-s',$Serial,'shell',"dd if='$superDev' of='$remote/verify_$b.bin' bs=4096 skip=$b count=1 2>/dev/null; sha256sum '$remote/verify_$b.bin' | awk '{print `$1}'")
            $got = ($got -split "`n")[-1].Trim().ToLowerInvariant()
            Write-Host "LIVE_TARGET_BLOCK=$b SHA256=$got"
            if ($got -ne $x.TargetSha) { throw "LIVE_TARGET_BLOCK_MISMATCH block=$b expected=$($x.TargetSha) got=$got" }
        }
    } catch {
        $err=$_
        if ($writeStarted) {
            Write-Host 'LIVE_PATCH_ERROR_ROLLBACK=START'
            foreach ($b in $ExpectedRawBlocks) {
                try { Invoke-AdbText @('-s',$Serial,'shell',"dd if='$backup/block_$b.bin' of='$superDev' bs=4096 seek=$b count=1 conv=notrunc 2>/dev/null") | Out-Null } catch {}
            }
            try { Invoke-AdbText @('-s',$Serial,'shell','sync') | Out-Null } catch {}
            $rollbackOk=$true
            foreach ($b in $ExpectedRawBlocks) {
                $x=$blockInfo[[string][Int64]$b]
                try {
                    $got = Invoke-AdbText @('-s',$Serial,'shell',"dd if='$superDev' of='$remote/rollback_$b.bin' bs=4096 skip=$b count=1 2>/dev/null; sha256sum '$remote/rollback_$b.bin' | awk '{print `$1}'")
                    $got = ($got -split "`n")[-1].Trim().ToLowerInvariant()
                    if ($got -ne $x.SourceSha) { $rollbackOk=$false }
                } catch { $rollbackOk=$false }
            }
            if ($rollbackOk) { Write-Host 'LIVE_PATCH_ROLLBACK=PASS' } else { Write-Host 'LIVE_PATCH_ROLLBACK=FAIL' }
        }
        throw $err
    }

    Write-Host 'LIVE_DIAG4_TARGET_BLOCKS=PASS'
    Write-Host 'MARKERS_RESET=04,12,17'
    Write-Host "BACKUP_PATH=$backup"
    Write-Host 'RESULT=DIAG4_LIVE_PATCH_PASS'
    Write-Host 'NEXT=DO_NOT_REFLASH_SUPER; reboot Android once, then return to CEV2 recovery and inspect /metadata/vold/d/04,12,17'
}
finally {
    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}
