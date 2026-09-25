# Valheim Server Infra

Infraestructura como código para dejar preparado un servidor dedicado de
Valheim en una VPS de Clouding.io. Este repositorio está separado de
`PH-Control`.

Estado actual: no se despliega nada automáticamente. El workflow de
provisionamiento es manual y solo crea recursos cuando alguien ejecuta
explícitamente `apply`.

## Qué falta parametrizar

### Clouding.io

Completar `terraform/terraform.tfvars` a partir de
`terraform/terraform.tfvars.example`:

- `image_id`, `flavor_id` y `ssh_key_id` de Clouding.io.
- `admin_cidr`: tu IP pública en formato CIDR para restringir SSH.
- `server_name`, `hostname` y `ssd_gb`, si quieres cambiar los valores base.
- `clouding_backup_enabled`, `clouding_backup_frequency` y
  `clouding_backup_slots` si deseas snapshots administrados por Clouding.

`ssh_key_id` es el ID del recurso de llave pública registrado en Clouding; no
es la llave privada.

### HCP Terraform y GitHub

- Crear o elegir una organización de HCP Terraform.
- Configurar la organización en `TF_CLOUD_ORGANIZATION`.
- El workspace remoto será `valheim-server-infra`; `terraform init` lo crea o
  lo usa dentro de esa organización.
- En local, `provision.ps1` puede solicitar `CLOUDING_TOKEN` y el token de HCP
  (`TF_TOKEN_app_terraform_io`) en memoria si no están definidos.
- En el Environment de GitHub llamado `provisioning`, guardar los secretos
  `CLOUDING_TOKEN`, `TF_API_TOKEN`, `CLOUDING_IMAGE_ID`,
  `CLOUDING_FLAVOR_ID`, `CLOUDING_SSH_KEY_ID` y `VALHEIM_ADMIN_CIDR`.
- Restringir ese Environment a la rama `main` y exigir aprobación manual antes
  de cualquier ejecución que use secretos, especialmente `apply`.

La llave privada SSH no se usa para crear la VPS ni debe entrar en Terraform
State. Solo será necesaria después, para migrar o restaurar el mundo.

### Valheim y backups

Después de crear la VPS todavía hay que definir en el servidor:

- `VALHEIM_PASSWORD` y, si aplica, `VALHEIM_WORLD`, `VALHEIM_NAME` y
  `VALHEIM_EXTRA_ARGS` en `/etc/valheim/valheim.env`.
- El host, usuario y ruta de la llave SSH para los scripts de migración.
- Opcionalmente, las credenciales de B2 en `/etc/valheim/backup.env`.

El backup externo B2 es opcional y usa los mismos nombres que `PH-Control`:
`B2_S3_ENDPOINT`, `B2_S3_REGION`, `B2_BUCKET`, `B2_KEY_ID`,
`B2_APPLICATION_KEY`, `RESTIC_PASSWORD_FILE` y, opcionalmente,
`RESTIC_REPOSITORY`. Se recomienda un bucket privado separado y una
Application Key limitada a ese bucket. Ningún valor se guarda en Git.

## Flujo para implementarlo en el futuro

### 1. Validar localmente sin credenciales ni despliegue

Desde la raíz del repositorio:

```powershell
terraform -chdir=terraform init -backend=false -lockfile=readonly
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform validate
```

### 2. Preparar variables

```powershell
Copy-Item terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Editar `terraform/terraform.tfvars`. Ese archivo está ignorado por Git y no
debe contener llaves privadas ni tokens.

### 3. Previsualizar o crear la VPS desde PowerShell

El wrapper solicita los tokens que falten sin escribirlos a disco:

```powershell
.\scripts\provision.ps1 -Action plan -HcpOrganization "MI_ORGANIZACION"
.\scripts\provision.ps1 -Action apply -HcpOrganization "MI_ORGANIZACION"
```

`plan` solo muestra cambios. `apply` crea infraestructura facturable. No usar
`apply` hasta haber revisado el plan y los valores de Clouding.

### 4. Usar GitHub Actions, si se prefiere CI/CD

- Pull requests y pushes a `main` ejecutan solo formato, inicialización sin
  backend y validación.
- `Terraform Provision` se ejecuta manualmente con `workflow_dispatch`, pero
  el job solo acepta la rama `main` para evitar exponer secretos desde ramas
  arbitrarias.
- `plan` genera una previsualización.
- `apply` está permitido únicamente en `main` y requiere el Environment
  `provisioning`.

El push del repositorio no despliega la VPS; el workflow de provisionamiento
no tiene ejecución automática.

### 5. Activar Valheim después del provisionamiento

Conectarse por SSH, configurar la contraseña real y arrancar el servicio:

```bash
sudoedit /etc/valheim/valheim.env
sudo systemctl start valheim
sudo systemctl status valheim
```

La contraseña debe tener al menos cinco caracteres. El bootstrap instala el
servidor, pero lo deja detenido hasta que se configure una contraseña válida.

### 6. Migrar el mundo actual

Desde Windows, el script busca `<WorldName>.db` y `<WorldName>.fwl` en la
carpeta local de Valheim, conserva el estado anterior en el servidor y arranca
el servicio con el mundo indicado:

```powershell
.\scripts\upload-world.ps1 `
  -WorldName "MiMundo" `
  -RemoteHost "IP_DE_LA_VPS" `
  -RemoteUser "USUARIO_SSH" `
  -IdentityFile "$env:USERPROFILE\.ssh\valheim_ed25519"
```

### 7. Verificar backups

Siempre se crea un backup local diario, con 14 días de retención:

```bash
systemctl list-timers valheim-backup.timer
sudo systemctl start valheim-backup.service
journalctl -u valheim-backup.service
```

Para activar el backup externo, completar `/etc/valheim/backup.env`, crear el
archivo de contraseña de Restic con permisos `0600` y ejecutar el servicio una
vez manualmente. La limpieza de Restic filtra por el tag `valheim-world`; aun
así, usa un repositorio dedicado. Si B2 no está parametrizado, el sistema
conserva solamente los backups locales.

### 8. Restaurar un backup

El script conserva el estado actual como `pre-restore-*` antes de extraer el
archivo elegido:

```powershell
.\scripts\restore-world.ps1 `
  -ArchiveName "worlds-AAAAMMDDHHMMSS.tgz" `
  -RemoteHost "IP_DE_LA_VPS" `
  -RemoteUser "USUARIO_SSH" `
  -IdentityFile "$env:USERPROFILE\.ssh\valheim_ed25519"
```

## Qué hace cada archivo importante

### Scripts de PowerShell

- `scripts/provision.ps1`: prepara el backend remoto de HCP Terraform,
  comprueba formato y configuración, ejecuta `plan` y solo ejecuta `apply` si
  se solicita explícitamente.
- `scripts/upload-world.ps1`: valida y sube los archivos `.db` y `.fwl`,
  detiene Valheim, conserva el mundo anterior, actualiza `VALHEIM_WORLD` y
  vuelve a iniciar el servicio.
- `scripts/restore-world.ps1`: valida un archivo `.tgz` existente, conserva el
  mundo actual, restaura el backup, corrige permisos y reinicia Valheim.

### Terraform y bootstrap

- `terraform/main.tf`: crea la VPS y el firewall; expone SSH solo a
  `admin_cidr` y los puertos UDP `2456-2457` para Valheim.
- `terraform/variables.tf`: concentra los parámetros del servidor, Clouding y
  backups administrados.
- `terraform/cloud-init.yaml`: instala SteamCMD, Valheim, UFW, systemd y el
  backup local diario; también prepara el backup B2 opcional con Restic.
- `terraform/backend.tf`: configura el state remoto en HCP Terraform.
- `.github/workflows/terraform-validate.yml`: valida cambios sin secretos ni
  recursos reales.
- `.github/workflows/terraform-provision.yml`: ofrece `plan` y `apply` manuales
  usando secretos de GitHub.

## Resumen de backups

- Backup local diario a las 03:00 UTC: habilitado por defecto, retención de 14
  días.
- Backup externo B2 con Restic: opcional y parametrizable; protege frente a la
  pérdida completa de la VPS.
- Backups administrados por Clouding: opcionales y deshabilitados por defecto
  para evitar cargos inesperados.
- Actualizaciones de seguridad de Ubuntu: habilitadas mediante
  `unattended-upgrades`.
- HCP Terraform solo guarda el state de infraestructura; nunca el mundo de
  Valheim.

## Seguridad

No guardar en el repositorio tokens, contraseñas, llaves privadas, archivos
`.tfvars` reales ni valores de B2. `terraform.tfvars` está ignorado por Git y
los secretos de CI deben vivir en GitHub Environment Secrets. Los scripts SSH
exigen `StrictHostKeyChecking=yes`; registra y verifica la huella del servidor
antes de usarlos. `admin_cidr` se aplica tanto al firewall de Clouding como a
UFW y se rechaza `0.0.0.0/0`/`::/0`. Las acciones de GitHub están fijadas a
commits y Dependabot propone sus actualizaciones.
