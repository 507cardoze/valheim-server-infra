[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidatePattern("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")]
  [string] $WorldName,

  [Parameter(Mandatory = $true)]
  [string] $RemoteHost,

  [Parameter(Mandatory = $true)]
  [string] $RemoteUser,

  [Parameter(Mandatory = $true)]
  [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
  [string] $IdentityFile,

  [string] $WorldDirectory = (Join-Path $env:USERPROFILE "AppData\LocalLow\IronGate\Valheim\worlds_local")
)

$ErrorActionPreference = "Stop"

$sshCommand = Get-Command ssh -ErrorAction SilentlyContinue
$scpCommand = Get-Command scp -ErrorAction SilentlyContinue
if ($null -eq $sshCommand -or $null -eq $scpCommand) {
  throw "OpenSSH commands ssh and scp are required."
}

if (-not (Test-Path -LiteralPath $WorldDirectory -PathType Container)) {
  throw "World directory not found: $WorldDirectory"
}

$dbPath = Join-Path $WorldDirectory "$WorldName.db"
$fwlPath = Join-Path $WorldDirectory "$WorldName.fwl"
foreach ($path in @($dbPath, $fwlPath)) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Expected world file not found: $path"
  }
}

$target = "$RemoteUser@$RemoteHost"
$remoteDb = "/tmp/valheim-world-import.db"
$remoteFwl = "/tmp/valheim-world-import.fwl"
$remoteDbTarget = "{0}:{1}" -f $target, $remoteDb
$remoteFwlTarget = "{0}:{1}" -f $target, $remoteFwl

& $scpCommand.Source -i $IdentityFile -o BatchMode=yes $dbPath $remoteDbTarget
if ($LASTEXITCODE -ne 0) {
  throw "Could not upload the Valheim database file."
}

& $scpCommand.Source -i $IdentityFile -o BatchMode=yes $fwlPath $remoteFwlTarget
if ($LASTEXITCODE -ne 0) {
  throw "Could not upload the Valheim metadata file."
}

$remoteScript = @'
set -euo pipefail

world_name="__WORLD_NAME__"
world_dir="/opt/valheim/data/worlds_local"
timestamp=$(date -u +%Y%m%d%H%M%S)
was_active=0

cleanup() {
  rm -f /tmp/valheim-world-import.db /tmp/valheim-world-import.fwl
  if [[ "$was_active" -eq 1 ]]; then
    sudo systemctl start valheim || true
  fi
}
trap cleanup EXIT

if sudo systemctl is-active --quiet valheim; then
  sudo systemctl stop valheim
  was_active=1
fi

sudo install -d -o valheim -g valheim -m 750 "$world_dir"
sudo install -d -o root -g root -m 700 /var/backups/valheim

if sudo test -f "$world_dir/$world_name.db"; then
  sudo cp "$world_dir/$world_name.db" "/var/backups/valheim/pre-import-$timestamp.db"
fi
if sudo test -f "$world_dir/$world_name.fwl"; then
  sudo cp "$world_dir/$world_name.fwl" "/var/backups/valheim/pre-import-$timestamp.fwl"
fi

sudo install -o valheim -g valheim -m 0640 /tmp/valheim-world-import.db "$world_dir/$world_name.db"
sudo install -o valheim -g valheim -m 0640 /tmp/valheim-world-import.fwl "$world_dir/$world_name.fwl"
sudo sed -i -E "s/^VALHEIM_WORLD=.*/VALHEIM_WORLD=\"$world_name\"/" /etc/valheim/valheim.env

sudo systemctl start valheim
sudo systemctl is-active --quiet valheim
was_active=0
echo "World import completed: $world_name"
'@.Replace("__WORLD_NAME__", $WorldName)

& $sshCommand.Source -i $IdentityFile -o BatchMode=yes $target $remoteScript
if ($LASTEXITCODE -ne 0) {
  throw "Remote world import failed. The previous world backup, if present, remains under /var/backups/valheim."
}
