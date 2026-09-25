[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidatePattern("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")]
  [string] $WorldName,

  [Parameter(Mandatory = $true)]
  [ValidatePattern("^(?:[A-Za-z0-9][A-Za-z0-9_.:-]{0,252}|\[[0-9A-Fa-f:.]+\])$")]
  [string] $RemoteHost,

  [Parameter(Mandatory = $true)]
  [ValidatePattern("^[A-Za-z_][A-Za-z0-9_.-]{0,31}$")]
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
$sshOptions = @(
  "-i", $IdentityFile,
  "-o", "BatchMode=yes",
  "-o", "IdentitiesOnly=yes",
  "-o", "StrictHostKeyChecking=yes"
)
$remoteImportDir = $null

try {
  $remoteImportDir = (& $sshCommand.Source @sshOptions $target "umask 077 && mktemp -d /tmp/valheim-world-import.XXXXXX" | Out-String).Trim()
  if ($LASTEXITCODE -ne 0 -or $remoteImportDir -notmatch '^/tmp/valheim-world-import\.[A-Za-z0-9]+$') {
    throw "Could not create a secure remote temporary directory. Register the server host key and try again."
  }

  $remoteDb = "$remoteImportDir/world.db"
  $remoteFwl = "$remoteImportDir/world.fwl"
  $remoteDbTarget = "{0}:{1}" -f $target, $remoteDb
  $remoteFwlTarget = "{0}:{1}" -f $target, $remoteFwl

  & $scpCommand.Source @sshOptions $dbPath $remoteDbTarget
  if ($LASTEXITCODE -ne 0) {
    throw "Could not upload the Valheim database file."
  }

  & $scpCommand.Source @sshOptions $fwlPath $remoteFwlTarget
  if ($LASTEXITCODE -ne 0) {
    throw "Could not upload the Valheim metadata file."
  }

  $remoteScript = @'
set -euo pipefail

world_name="__WORLD_NAME__"
import_dir="__IMPORT_DIR__"
remote_db="$import_dir/world.db"
remote_fwl="$import_dir/world.fwl"
world_dir="/opt/valheim/data/worlds_local"
timestamp=$(date -u +%Y%m%d%H%M%S)
was_active=0

cleanup() {
  rm -rf -- "$import_dir"
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

sudo install -o valheim -g valheim -m 0640 "$remote_db" "$world_dir/$world_name.db"
sudo install -o valheim -g valheim -m 0640 "$remote_fwl" "$world_dir/$world_name.fwl"
sudo sed -i -E "s/^VALHEIM_WORLD=.*/VALHEIM_WORLD=\"$world_name\"/" /etc/valheim/valheim.env

sudo systemctl start valheim
sudo systemctl is-active --quiet valheim
was_active=0
echo "World import completed: $world_name"
'@.Replace("__WORLD_NAME__", $WorldName).Replace("__IMPORT_DIR__", $remoteImportDir)

  & $sshCommand.Source @sshOptions $target $remoteScript
  if ($LASTEXITCODE -ne 0) {
    throw "Remote world import failed. The previous world backup, if present, remains under /var/backups/valheim."
  }
}
finally {
  if ($remoteImportDir -match '^/tmp/valheim-world-import\.[A-Za-z0-9]+$') {
    & $sshCommand.Source @sshOptions $target "rm -rf -- '$remoteImportDir'" | Out-Null
  }
}
