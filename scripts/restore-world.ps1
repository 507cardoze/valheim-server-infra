[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidatePattern("^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\.tgz$")]
  [string] $ArchiveName,

  [Parameter(Mandatory = $true)]
  [string] $RemoteHost,

  [Parameter(Mandatory = $true)]
  [string] $RemoteUser,

  [Parameter(Mandatory = $true)]
  [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
  [string] $IdentityFile,

  [ValidatePattern("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")]
  [string] $WorldName
)

$ErrorActionPreference = "Stop"

$sshCommand = Get-Command ssh -ErrorAction SilentlyContinue
if ($null -eq $sshCommand) {
  throw "OpenSSH command ssh is required."
}

$target = "$RemoteUser@$RemoteHost"
$worldNameValue = if ($null -eq $WorldName) { "" } else { $WorldName }
$remoteScript = @'
set -euo pipefail

archive_name="__ARCHIVE_NAME__"
world_name="__WORLD_NAME__"
backup_dir="/var/backups/valheim"
world_dir="/opt/valheim/data/worlds_local"
archive="$backup_dir/$archive_name"
timestamp=$(date -u +%Y%m%d%H%M%S)
was_active=0

if ! sudo test -f "$archive"; then
  echo "Backup archive not found: $archive" >&2
  exit 1
fi

cleanup() {
  if [[ "$was_active" -eq 1 ]]; then
    sudo systemctl start valheim || true
  fi
}
trap cleanup EXIT

if sudo systemctl is-active --quiet valheim; then
  sudo systemctl stop valheim
  was_active=1
fi

sudo install -d -o root -g root -m 700 "$backup_dir"
if [[ -n "$(sudo find "$world_dir" -maxdepth 1 -type f -name '*.db' -print -quit)" ]]; then
  sudo tar -czf "$backup_dir/pre-restore-$timestamp.tgz" -C "$world_dir" .
fi
sudo install -d -o valheim -g valheim -m 750 "$world_dir"
sudo tar -xzf "$archive" -C "$world_dir"
sudo chown -R valheim:valheim "$world_dir"

if [[ -n "$world_name" ]]; then
sudo sed -i -E "s/^VALHEIM_WORLD=.*/VALHEIM_WORLD=\"$world_name\"/" /etc/valheim/valheim.env
fi

sudo systemctl start valheim
sudo systemctl is-active --quiet valheim
was_active=0
echo "World restore completed from $archive_name"
'@.Replace("__ARCHIVE_NAME__", $ArchiveName).Replace("__WORLD_NAME__", $worldNameValue)

& $sshCommand.Source -i $IdentityFile -o BatchMode=yes $target $remoteScript
if ($LASTEXITCODE -ne 0) {
  throw "Remote world restore failed."
}
