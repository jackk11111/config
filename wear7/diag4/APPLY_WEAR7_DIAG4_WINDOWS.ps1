param(
    [string]$Super = "$env:USERPROFILE\Downloads\TicWatch_Wear7_DIAG3_FINAL\FlashKit\super_WEAR7_V11_DIAG3_FINAL.img"
)

$ErrorActionPreference = 'Stop'

$PatchUrl = 'https://raw.githubusercontent.com/jackk11111/config/wear7-diag4-init-bisect-20261002/wear7/diag4/DIAG4_PATCH.json'
$ExpectedSource = '75c8d716e0f243cfe309d9fca29aba0253f524bb70d93959dcd5d4fba0dc3329'
$ExpectedTarget = '5f15ab8fc99d7cf80b7edc1389a524549c891b700f228d84554ee8847c3a42ec'
$ExpectedRaw    = '24b607b5f7f7b59a7a73bd849c2fae355c5d738a2e47ffd774d3ae5388c08ac7'

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Restore-SourceBytes($Records, [string]$Path) {
    $fs = [System.IO.File]::Open(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
    try {
        foreach ($r in $Records) {
            $old = [Convert]::FromBase64String([string]$r.old_b64)
            [void]$fs.Seek([Int64]$r.sparse_offset, [System.IO.SeekOrigin]::Begin)
            $fs.Write($old, 0, $old.Length)
        }
        $fs.Flush($true)
    }
    finally {
        $fs.Dispose()
    }
}

Write-Host '===== WEAR7 DIAG4 IN-PLACE PATCH ====='
Write-Host "SUPER=$Super"

if (-not (Test-Path -LiteralPath $Super -PathType Leaf)) {
    throw "SUPER_NOT_FOUND=$Super"
}

$Patch = Invoke-RestMethod -Uri $PatchUrl -Headers @{ 'Cache-Control' = 'no-cache' }

if ([string]$Patch.source_sparse_sha256 -ne $ExpectedSource) {
    throw 'PATCH_METADATA_SOURCE_SHA_MISMATCH'
}
if ([string]$Patch.target_sparse_sha256 -ne $ExpectedTarget) {
    throw 'PATCH_METADATA_TARGET_SHA_MISMATCH'
}
if ([string]$Patch.target_raw_sha256 -ne $ExpectedRaw) {
    throw 'PATCH_METADATA_RAW_SHA_MISMATCH'
}
if ([int]$Patch.changed_raw_blocks -ne 6) {
    throw "PATCH_METADATA_BLOCK_COUNT_MISMATCH=$($Patch.changed_raw_blocks)"
}
if (@($Patch.records).Count -ne 31) {
    throw "PATCH_METADATA_RECORD_COUNT_MISMATCH=$(@($Patch.records).Count)"
}

$current = Get-Sha256 $Super
Write-Host "CURRENT_SHA256=$current"

if ($current -eq $ExpectedTarget) {
    Write-Host "TARGET_SHA256=$current"
    Write-Host 'RESULT=DIAG4_ALREADY_PATCHED'
    exit 0
}

if ($current -ne $ExpectedSource) {
    throw "SOURCE_SHA_MISMATCH expected=$ExpectedSource got=$current"
}

$records = @($Patch.records)
$fs = $null
$writeStarted = $false
$operationError = $null

try {
    $fs = [System.IO.File]::Open(
        $Super,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )

    # Full preflight: every source byte must match before the first write.
    foreach ($r in $records) {
        $old = [Convert]::FromBase64String([string]$r.old_b64)
        $new = [Convert]::FromBase64String([string]$r.new_b64)

        if ($old.Length -ne [int]$r.length -or $new.Length -ne [int]$r.length) {
            throw "PATCH_RECORD_LENGTH_MISMATCH offset=$($r.sparse_offset)"
        }

        [void]$fs.Seek([Int64]$r.sparse_offset, [System.IO.SeekOrigin]::Begin)
        $got = New-Object byte[] $old.Length
        $n = $fs.Read($got, 0, $got.Length)

        if ($n -ne $got.Length -or [Convert]::ToBase64String($got) -ne [string]$r.old_b64) {
            throw "PATCH_SOURCE_BYTES_MISMATCH offset=$($r.sparse_offset)"
        }
    }

    Write-Host 'SOURCE_BYTES_PREFLIGHT=PASS'

    $writeStarted = $true
    foreach ($r in $records) {
        $new = [Convert]::FromBase64String([string]$r.new_b64)
        [void]$fs.Seek([Int64]$r.sparse_offset, [System.IO.SeekOrigin]::Begin)
        $fs.Write($new, 0, $new.Length)
    }
    $fs.Flush($true)
}
catch {
    $operationError = $_
}
finally {
    if ($null -ne $fs) {
        $fs.Dispose()
    }
}

if ($null -ne $operationError) {
    if ($writeStarted) {
        Write-Host 'WRITE_ERROR_ROLLBACK=START'
        Restore-SourceBytes $records $Super
        $rollbackHash = Get-Sha256 $Super
        Write-Host "ROLLBACK_SHA256=$rollbackHash"
        if ($rollbackHash -ne $ExpectedSource) {
            throw "ROLLBACK_HASH_MISMATCH original_error=$($operationError.Exception.Message)"
        }
        throw "DIAG4_PATCH_WRITE_FAILED_ROLLED_BACK_OK original_error=$($operationError.Exception.Message)"
    }
    throw $operationError
}

$after = Get-Sha256 $Super
Write-Host "TARGET_SHA256=$after"

if ($after -ne $ExpectedTarget) {
    Write-Host 'TARGET_HASH_FAIL_ROLLBACK=START'
    Restore-SourceBytes $records $Super
    $rollbackHash = Get-Sha256 $Super
    Write-Host "ROLLBACK_SHA256=$rollbackHash"

    if ($rollbackHash -ne $ExpectedSource) {
        throw "ROLLBACK_HASH_MISMATCH expected=$ExpectedSource got=$rollbackHash"
    }
    throw "DIAG4_TARGET_HASH_MISMATCH_ROLLED_BACK_OK expected=$ExpectedTarget got=$after"
}

Write-Host 'CHANGED_RAW_BLOCKS=6'
Write-Host 'PATCH_RECORDS=31'
Write-Host "TARGET_RAW_SHA256=$ExpectedRaw"
Write-Host 'RESULT=DIAG4_PATCH_PASS'
Write-Host 'NO_FLASH_PERFORMED=YES'
