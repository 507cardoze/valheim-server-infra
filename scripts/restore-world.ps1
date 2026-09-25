[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidatePattern("^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\.tgz$")]
  [string] $ArchiveName,

  [Parameter(Mandatory = $true)]
  [ValidatePattern("^(?:[A-Za-z0-9][A-Za-z0-9_.:-]{0,252}|\[[0-9A-Fa-f:.]+\])$")]
  [string] $RemoteHost,

  [Parameter(Mandatory = $true)]
  [ValidatePattern("^[A-Za-z_][A-Za-z0-9_.-]{0,31}$")]
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
$sshOptions = @(
  "-i", $IdentityFile,
  "-o", "BatchMode=yes",
  "-o", "IdentitiesOnly=yes",
  "-o", "StrictHostKeyChecking=yes"
)
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
restore_dir=""

if ! sudo test -f "$archive"; then
  echo "Backup archive not found: $archive" >&2
  exit 1
fi

if ! sudo tar -tzf "$archive" | awk '
  {
    entry=$0
    name=entry
    sub(/\/$/, "", name)
    if (name == "." || name == "") {
      next
    }
    if (entry ~ /\/$/ || name !~ /^\.[\/][A-Za-z0-9][A-Za-z0-9_.-]*$/) {
      print "Unsafe archive entry: " name > "/dev/stderr"
      invalid=1
    }
  }
  END { exit invalid }
'; then
  echo "Backup archive contains an unsafe path." >&2
  exit 1
fi

if ! sudo tar -tvzf "$archive" | awk '
  {
    entry_type=substr($1, 1, 1)
    if (entry_type != "-" && entry_type != "d") {
      print "Unsupported archive entry type: " $0 > "/dev/stderr"
      invalid=1
    }
  }
  END { exit invalid }
'; then
  echo "Backup archive contains links or special files." >&2
  exit 1
fi

restore_dir=$(sudo mktemp -d /tmp/valheim-restore.XXXXXX)
sudo chmod 700 "$restore_dir"

cleanup() {
  if [[ -n "$restore_dir" ]]; then
    sudo rm -rf -- "$restore_dir"
  fi
  if [[ "$was_active" -eq 1 ]]; then
    sudo systemctl start valheim || true
  fi
}
trap cleanup EXIT

sudo tar --extract --gzip --file="$archive" --directory="$restore_dir" \
  --no-same-owner --no-same-permissions --no-overwrite-dir
restored_db=$(sudo find "$restore_dir" -maxdepth 1 -type f -name '*.db' -print -quit)
if [[ -z "$restored_db" ]]; then
  echo "Backup archive does not contain a world database." >&2
  exit 1
fi

if sudo systemctl is-active --quiet valheim; then
  sudo systemctl stop valheim
  was_active=1
fi

sudo install -d -o root -g root -m 700 "$backup_dir"
if [[ -n "$(sudo find "$world_dir" -maxdepth 1 -type f -name '*.db' -print -quit)" ]]; then
  sudo tar -czf "$backup_dir/pre-restore-$timestamp.tgz" -C "$world_dir" .
fi
sudo install -d -o valheim -g valheim -m 750 "$world_dir"
sudo cp -a "$restore_dir"/. "$world_dir"/
sudo chown -R valheim:valheim "$world_dir"
sudo find "$world_dir" -maxdepth 1 -type f -exec chmod 0640 {} \;

if [[ -n "$world_name" ]]; then
sudo sed -i -E "s/^VALHEIM_WORLD=.*/VALHEIM_WORLD=\"$world_name\"/" /etc/valheim/valheim.env
fi

sudo systemctl start valheim
sudo systemctl is-active --quiet valheim
was_active=0
echo "World restore completed from $archive_name"
'@.Replace("__ARCHIVE_NAME__", $ArchiveName).Replace("__WORLD_NAME__", $worldNameValue)

& $sshCommand.Source @sshOptions $target $remoteScript
if ($LASTEXITCODE -ne 0) {
  throw "Remote world restore failed."
}
