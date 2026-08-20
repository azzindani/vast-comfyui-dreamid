# Push input files to the instance, or pull finished renders back.
#
#   .\upload.ps1 -Push C:\video\face.jpg
#   .\upload.ps1 -Push C:\video\test2s.mp4
#   .\upload.ps1 -Pull result.mp4 -To C:\Users\me\Videos
#
# Note: scp uses a CAPITAL -P for port. ssh uses lowercase -p. Easy to trip on.

param(
    [string]$VastHost = "",
    [int]$Port        = 0,
    [string]$Push     = "",
    [string]$Pull     = "",
    [string]$To       = "."
)

# --- same defaults as connect.ps1 -------------------------------------------
$DefaultHost = ""
$DefaultPort = 0
# ---------------------------------------------------------------------------

if (-not $VastHost) { $VastHost = $DefaultHost }
if (-not $Port)     { $Port     = $DefaultPort }

if (-not $VastHost -or -not $Port) {
    Write-Host "Set `$DefaultHost and `$DefaultPort in this file first." -ForegroundColor Yellow
    exit 1
}

$InputDir  = "/workspace/ComfyUI/input"
$OutputDir = "/workspace/ComfyUI/output"

if ($Push) {
    if (-not (Test-Path $Push)) {
        Write-Host "No such file: $Push" -ForegroundColor Red
        exit 1
    }
    Write-Host "Uploading $(Split-Path $Push -Leaf) -> $InputDir" -ForegroundColor Cyan
    scp -P $Port $Push "root@${VastHost}:${InputDir}/"
}
elseif ($Pull) {
    Write-Host "Downloading $Pull -> $To" -ForegroundColor Cyan
    scp -P $Port "root@${VastHost}:${OutputDir}/$Pull" $To
}
else {
    Write-Host "Pass -Push <localfile> or -Pull <remotefilename>" -ForegroundColor Yellow
    Write-Host "`nRemote listing:" -ForegroundColor DarkGray
    ssh -p $Port "root@$VastHost" "ls -lh $InputDir $OutputDir"
}
