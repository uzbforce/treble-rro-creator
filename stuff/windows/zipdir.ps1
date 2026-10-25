# ---------------------------------------------------------------------------
# zipdir.ps1 - create a zip archive from a directory
# ---------------------------------------------------------------------------
# build.sh calls this on Windows, where Git for Windows ships no `zip` binary.
# It writes POSIX-style entry names ("system/product/overlay/x.apk") and Unix
# modes (0100755 for *.sh, update-binary and the FOD helper, 0100644 otherwise),
# so the result is byte-compatible with what Info-ZIP produces on Linux/Termux.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File windows/zipdir.ps1 `
#       -Source <directory> -Dest <file.zip>
# ---------------------------------------------------------------------------
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Dest
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
    Write-Error "Source directory not found: $Source"
    exit 1
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$src = [System.IO.Path]::GetFullPath($Source).TrimEnd('\')
$destFull = [System.IO.Path]::GetFullPath($Dest)
$destDir = [System.IO.Path]::GetDirectoryName($destFull)
if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
}
if (Test-Path -LiteralPath $destFull) {
    Remove-Item -LiteralPath $destFull -Force
}

$files = @(Get-ChildItem -LiteralPath $src -Recurse -File -Force)
if ($files.Count -eq 0) {
    Write-Error "Nothing to archive in $src"
    exit 1
}

$fs = [System.IO.File]::Open($destFull, [System.IO.FileMode]::CreateNew)
try {
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($f in $files) {
            # Always use forward slashes: the module installer extracts on Android.
            $rel = $f.FullName.Substring($src.Length + 1).Replace('\', '/')
            $entry = $zip.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = $f.LastWriteTime
            if ($f.Extension -eq '.sh' -or $f.Name -eq 'update-binary' -or $rel -eq 'fod/xiaomi-fod') {
                $entry.ExternalAttributes = 0x81ED -shl 16   # 0100755
            } else {
                $entry.ExternalAttributes = 0x81A4 -shl 16   # 0100644
            }
            $in = [System.IO.File]::OpenRead($f.FullName)
            try {
                $out = $entry.Open()
                try { $in.CopyTo($out) } finally { $out.Dispose() }
            } finally { $in.Dispose() }
        }
    } finally { $zip.Dispose() }
} finally { $fs.Dispose() }

# .NET stamps entries as "version made by = 2.0 (FAT)", which makes extractors
# ignore the Unix mode we put in ExternalAttributes. Relabel each central
# directory entry as created on Unix (host 0x03) so busybox/7-Zip honour 0755.
function Set-UnixMadeBy {
    param([string]$Path)

    $b = [System.IO.File]::ReadAllBytes($Path)

    # Locate the end-of-central-directory record (scan backwards from the end)
    $eocd = -1
    for ($i = $b.Length - 22; $i -ge 0; $i--) {
        if ($b[$i] -eq 0x50 -and $b[$i + 1] -eq 0x4B -and $b[$i + 2] -eq 0x05 -and $b[$i + 3] -eq 0x06) {
            $eocd = $i
            break
        }
    }
    if ($eocd -lt 0) { return }

    $count = [BitConverter]::ToUInt16($b, $eocd + 10)
    $offset = [BitConverter]::ToInt32($b, $eocd + 16)

    for ($n = 0; $n -lt $count; $n++) {
        if ($offset + 46 -gt $b.Length) { break }
        if ($b[$offset] -ne 0x50 -or $b[$offset + 1] -ne 0x4B -or
            $b[$offset + 2] -ne 0x01 -or $b[$offset + 3] -ne 0x02) { break }
        $b[$offset + 4] = 0x14   # version 2.0
        $b[$offset + 5] = 0x03   # host: Unix
        $nameLen = [BitConverter]::ToUInt16($b, $offset + 28)
        $extraLen = [BitConverter]::ToUInt16($b, $offset + 30)
        $commentLen = [BitConverter]::ToUInt16($b, $offset + 32)
        $offset += 46 + $nameLen + $extraLen + $commentLen
    }

    [System.IO.File]::WriteAllBytes($Path, $b)
}

Set-UnixMadeBy -Path $destFull

Write-Output "  zipped $($files.Count) files -> $Dest"
