# Connect to the vast.ai instance from Windows.
#
#   .\connect.ps1 -VastHost 12.34.56.78 -Port 12345
#
# Connects, forwards ComfyUI to http://localhost:8188, and reattaches tmux.
# Save your values in the defaults below so you can just run .\connect.ps1

param(
    [string]$VastHost = "",
    [int]$Port        = 0,
    [int]$LocalPort   = 8188
)

# --- fill these in to avoid passing arguments every time --------------------
$DefaultHost = ""
$DefaultPort = 0
# ---------------------------------------------------------------------------

if (-not $VastHost) { $VastHost = $DefaultHost }
if (-not $Port)     { $Port     = $DefaultPort }

if (-not $VastHost -or -not $Port) {
    Write-Host "Set `$DefaultHost and `$DefaultPort in this file, or pass -VastHost and -Port." -ForegroundColor Yellow
    Write-Host "Find both on your vast.ai instance card (the direct SSH command)." -ForegroundColor Yellow
    exit 1
}

# 18188 is ComfyUI itself. 8188 is Caddy, which sits behind portal auth --
# tunnelling straight to 18188 skips the login prompt.
$RemoteComfyPort = 18188

Write-Host "Connecting to $VastHost`:$Port" -ForegroundColor Cyan
Write-Host "ComfyUI will be at http://localhost:$LocalPort" -ForegroundColor Green
Write-Host "Keep this window open -- the tunnel dies with the session.`n" -ForegroundColor DarkGray

ssh -p $Port "root@$VastHost" `
    -L "${LocalPort}:localhost:${RemoteComfyPort}" `
    -t "tmux attach -t work || tmux new -s work"
