param(
  [string]$Dest = "$env:USERPROFILE\Downloads\TicWatch_Wear7_DIAG3_FINAL"
)

$ErrorActionPreference = 'Stop'
$Tag = 'wear7-diag3-final-20261002'
$Base = "https://github.com/jackk11111/config/releases/download/$Tag"
$FinalSha = '75c8d716e0f243cfe309d9fca29aba0253f524bb70d93959dcd5d4fba0dc3329'
$FlashKitSha = '6fb5dc482e37f26157ecf836427be072f74f9ec6fc41017d9b203e7f0d2894db'

$Parts = @(
  @{N='00'; H='8bdd4717609145adde24a17b2e2c8d9277736eb29208718f972b731c0e252e2e'},
  @{N='01'; H='9ee7093f50b780eb1a8e58f3b4a06f07e940e65fd6ca476522bcc7b6cb22f745'},
  @{N='02'; H='99f59565e631e63b39e1735e5cff73d5d600381d95b60ee943fa426abdccfadb'},
  @{N='03'; H='b1b4900d903ac6a18e098aeffa80caea118f26c5d51cdd77794b15eeda82f443'},
  @{N='04'; H='578b7b05b76534adcba334edd73b9d5c4059529827870a6a254c5af421a91dbd'},
  @{N='05'; H='f140922698da12c04664f0c0a4893ce35ad6e0744b3e25d3baa6a40d70227b26'},
  @{N='06'; H='888b948e50c9f437fbfcdd19973315c9b93f0b9b5d3b472d0e311f9d3a961b5c'},
  @{N='07'; H='78cfbe3d498c1d14a533c8739580cdd00890f96831bc6149be8971461a2d5b0c'},
  @{N='08'; H='7405095562990e4c114532dfe7ec5fc30cbc7a6950266d4ab2a932f8d0702138'},
  @{N='09'; H='9e3ef8d64bff496337484bb475ebd69e55548611adc363b4d65ee771e4696166'}
)

New-Item -ItemType Directory -Force -Path $Dest | Out-Null
$Temp = Join-Path $Dest '_tmp_parts'
New-Item -ItemType Directory -Force -Path $Temp | Out-Null
$Super = Join-Path $Dest 'super_WEAR7_V11_DIAG3_FINAL.img'
if (Test-Path $Super) { Remove-Item -Force $Super }

$out = [System.IO.File]::Open($Super, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
try {
  foreach ($p in $Parts) {
    $name = "super_WEAR7_V11_DIAG3_FINAL.img.part$($p.N)"
    $file = Join-Path $Temp $name
    $url = "$Base/$name"
    Write-Host "DOWNLOAD=$name"
    & curl.exe -fL --retry 3 --retry-delay 2 -o $file $url
    if ($LASTEXITCODE -ne 0) { throw "Download failed: $name" }
    $got = (Get-FileHash -Algorithm SHA256 $file).Hash.ToLowerInvariant()
    if ($got -ne $p.H) { throw "SHA256 mismatch for $name : $got" }
    $in = [System.IO.File]::OpenRead($file)
    try { $in.CopyTo($out) } finally { $in.Dispose() }
    Remove-Item -Force $file
    Write-Host "OK=$name"
  }
}
finally {
  $out.Dispose()
}

$gotFinal = (Get-FileHash -Algorithm SHA256 $Super).Hash.ToLowerInvariant()
if ($gotFinal -ne $FinalSha) { throw "FINAL SUPER SHA256 mismatch: $gotFinal" }
Write-Host "SUPER_SHA256=$gotFinal"

$Zip = Join-Path $Dest 'Wear7-DIAG3-Final-FlashKit-NoSuper-V2.zip'
& curl.exe -fL --retry 3 --retry-delay 2 -o $Zip "$Base/Wear7-DIAG3-Final-FlashKit-NoSuper-V2.zip"
if ($LASTEXITCODE -ne 0) { throw 'FlashKit download failed' }
$gotZip = (Get-FileHash -Algorithm SHA256 $Zip).Hash.ToLowerInvariant()
if ($gotZip -ne $FlashKitSha) { throw "FLASHKIT SHA256 mismatch: $gotZip" }

$KitRoot = Join-Path $Dest 'FlashKit'
if (Test-Path $KitRoot) { Remove-Item -Recurse -Force $KitRoot }
New-Item -ItemType Directory -Force -Path $KitRoot | Out-Null
Expand-Archive -Path $Zip -DestinationPath $KitRoot -Force
$cmd = Get-ChildItem -Path $KitRoot -Recurse -Filter 'FLASH_WEAR7_DIAG3_WINDOWS.cmd' | Select-Object -First 1
if (-not $cmd) { throw 'FLASH_WEAR7_DIAG3_WINDOWS.cmd not found after extraction' }
$RunDir = $cmd.Directory.FullName
$TargetSuper = Join-Path $RunDir 'super_WEAR7_V11_DIAG3_FINAL.img'
if ($Super -ne $TargetSuper) { Move-Item -Force $Super $TargetSuper }
Remove-Item -Force $Zip
Remove-Item -Recurse -Force $Temp

Write-Host ''
Write-Host 'READY=YES'
Write-Host "DIR=$RunDir"
Write-Host "SUPER_SHA256=$FinalSha"
Write-Host 'NO_FLASH_PERFORMED=YES'
