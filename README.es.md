# Claude Code History Guard

**Respaldos locales y copia de conversaciones de Claude Code Desktop entre cuentas en Windows.**

[English](README.md) · [Uso y recuperación](docs/usage.md) · [Modelo de seguridad](docs/safety.md)

Conserva el historial local antes de cambiar de cuenta: primero muestra un plan,
después verifica un respaldo y finalmente agrega los metadatos que falten. El
motor no reemplaza conversaciones existentes ni modifica definiciones de tareas,
grupos, credenciales o ajustes de Claude.

> Proyecto independiente y experimental. No transfiere chats web ni es una función
> oficial de Anthropic. Hay que salir completamente de Claude antes de copiar.
> Los respaldos reducen el riesgo; no garantizan que una pérdida sea imposible.

## Qué permite hacer

- Inspeccionar las carpetas y revisar el plan sin escribir en ellas.
- Copiar solamente conversaciones locales que falten en las cuentas elegidas.
- Conservar versiones verificadas mediante SHA-256, sin borrar respaldos antiguos.
- Recuperar un respaldo en una carpeta nueva y separada del perfil activo.
- Instalar opcionalmente un ayudante que espere al cierre de Claude.
- Abrir Claude con un acceso que compruebe el respaldo y la copia antes de iniciarlo.

El ayudante automático comparte nombres de sesiones **nuevas**. Las conversaciones
que ya existen al instalar quedan excluidas de esa automatización; para ellas se
utiliza la copia manual. Los historiales permanecen en la carpeta local compartida
de proyectos; se agregan los metadatos que permiten encontrarlos desde otra cuenta.

## Antes de empezar

Necesitas Windows, PowerShell 7, Node.js para la verificación independiente y
espacio libre para las versiones de los respaldos. Elige explícitamente las
cuentas y organizaciones cuyos datos estás autorizado a utilizar. Una carpeta
vacía puede ser antigua: no selecciones automáticamente todas las carpetas.

```powershell
pwsh -NoProfile -File ./Run-Tests.ps1 -Tier Quick
./Sync-ClaudeSessionsSafe.ps1 -Mode Inspect
```

Las pruebas generan conversaciones ficticias. No leen tu perfil de Claude.
Configura las rutas y las cuentas en un archivo privado fuera del repositorio:

```powershell
$sessions = '<ruta local absoluta de sesiones>'
$projects = Join-Path $env:USERPROFILE '.claude\projects'
$scopes = @('<uuid-cuenta>/<uuid-organizacion>', '<uuid-cuenta>/<uuid-organizacion>')
$backups = Join-Path $env:LOCALAPPDATA 'ClaudeHistoryGuardBackups'

./Sync-ClaudeSessionsSafe.ps1 -Mode Preview -SessionRoot $sessions `
  -TranscriptRoot $projects -Scopes $scopes
```

Lee el plan y usa **Salir/Quit en el icono de Claude de la bandeja**, junto al
reloj. Cerrar únicamente la ventana puede dejar la aplicación abierta.

```powershell
$snapshot = ./Backup-ClaudeHistorySafe.ps1 -Mode Create `
  -SessionRoot $sessions -TranscriptRoot $projects -BackupRoot $backups
./Backup-ClaudeHistorySafe.ps1 -Mode Verify -SnapshotPath $snapshot.SnapshotPath
./Sync-ClaudeSessionsSafe.ps1 -Mode Apply -SessionRoot $sessions `
  -TranscriptRoot $projects -Scopes $scopes -BackupRoot (Join-Path $backups 'metadata')
```

Mantén los respaldos fuera de los datos de Claude y del repositorio. La carpeta de
preparación de metadatos debe estar en la misma unidad local que las sesiones.
Revisa los conflictos y comprueba primero una sola conversación en la interfaz.

## Automatizar las conversaciones nuevas

Después de la comprobación manual, prepara la instalación:

```powershell
./Install-ClaudeHistoryAutomatic.ps1 -Mode Preview `
  -SessionRoot $sessions -TranscriptRoot $projects -Scopes $scopes `
  -BackupRoot $backups -EvidencePath ./artifacts/test-evidence.json
# Revisa el resultado y repite con -Mode Install para activar el ayudante.
```

Se crean un acceso propio **Claude History Guard** en el Escritorio y otro en
Inicio de Windows. No se crea una tarea del Programador de tareas ni se modifican
los accesos de Claude.

1. Termina la conversación y sal completamente **antes de cambiar de cuenta**.
2. Abre **Claude History Guard** y espera a que termine la verificación.
3. Cambia de cuenta en Claude. Si la lista no se actualiza, sal y vuelve a abrir
   desde el mismo acceso para que Desktop recargue el historial.

No hay copia en caliente ni interceptación del cierre de sesión. Las cuentas
nuevas requieren registro explícito.

```powershell
./Control-ClaudeHistoryAutomatic.ps1 -Mode Status
./Control-ClaudeHistoryAutomatic.ps1 -Mode Pause
./Control-ClaudeHistoryAutomatic.ps1 -Mode Resume
```

## Privacidad y colaboración

El código de respaldo y copia funciona localmente, sin telemetría ni peticiones
de red. El repositorio solo contiene código, documentación y generadores de datos
ficticios. Nunca publiques historiales, identificadores de cuentas, configuraciones,
capturas ni registros sin revisar. Los respaldos pueden contener información sensible.

Puedes ejecutar la suite completa con `./Run-Tests.ps1 -Tier Full -RandomTrials 500`.
Consulta [las pruebas](docs/testing.md) y [cómo contribuir](CONTRIBUTING.md).
Si te resulta útil, una estrella ayuda a que otras personas encuentren el proyecto.

## Licencia

Publicado bajo la [licencia MIT](LICENSE). Puedes usar, modificar y redistribuir
el software, incluso comercialmente, conservando el aviso de copyright y la
licencia. Se entrega sin garantía; consulta LICENSE para los términos completos.

Claude y Claude Code son marcas de Anthropic. Este proyecto no está afiliado,
avalado ni soportado por Anthropic.
