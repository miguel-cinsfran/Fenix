<#
.SYNOPSIS
    Orquestador central para el motor de aprovisionamiento Fénix.
.DESCRIPTION
    Este script es el único punto de entrada. Carga los módulos de fase, gestiona el estado
    global (con persistencia inteligente), el menú principal, el logging y el manejo de interrupciones.
.NOTES
    Versión: 3.5
    Autor: miguel-cinsfran
    Requiere: Privilegios de Administrador. Estructura de directorios modular.
#>

# SECCIÃ“N 0: CONFIGURACIÃ“N DE CODIFICACIÃ“N UNIVERSAL
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# SECCIÃ“N 1: AUTO-ELEVACIÃ“N DE PRIVILEGIOS
if (-not ([System.Security.Principal.WindowsPrincipal][System.Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "Se requieren privilegios de Administrador. Relanzando..."
    Start-Process powershell -Verb RunAs -ArgumentList "-File `"$($myinvocation.mycommand.definition)`""
    exit
}

# SECCIÃ“N 2: INICIALIZACIÃ“N DEL CONTEXTO GLOBAL
$Global:PhoenixContext = [PSCustomObject]@{
    Paths    = @{}
    Settings = @{}
    Theme    = @{}
    Flags    = @{
        UseWingetCli = $false
    }
}

try {
    $configFile = Join-Path $PSScriptRoot "settings.psd1"
    $Global:PhoenixContext.Settings = Import-PowerShellDataFile -Path $configFile
} catch {
    Write-Error "No se pudo cargar el fichero de configuración 'settings.psd1'. El script no puede continuar."
    Request-Continuation -Message "Presione Enter para salir."; exit
}

# Construir rutas absolutas y almacenarlas en el contexto
$Global:PhoenixContext.Paths.Root = $PSScriptRoot
$Global:PhoenixContext.Paths.Modules = Join-Path $PSScriptRoot $Global:PhoenixContext.Settings.Paths.Modules
$Global:PhoenixContext.Paths.Catalogs = Join-Path $PSScriptRoot $Global:PhoenixContext.Settings.Paths.Catalogs
$Global:PhoenixContext.Paths.Logs = Join-Path $PSScriptRoot $Global:PhoenixContext.Settings.Paths.Logs
$Global:PhoenixContext.Paths.LogFile = Join-Path $Global:PhoenixContext.Paths.Logs "$($Global:PhoenixContext.Settings.FileNames.LogBaseName)-$((Get-Date).ToString('yyyyMMdd-HHmmss')).txt"
$Global:PhoenixContext.Paths.ThemeFile = Join-Path $PSScriptRoot (Join-Path $Global:PhoenixContext.Settings.Paths.Themes $Global:PhoenixContext.Settings.FileNames.Theme)
$Global:PhoenixContext.Paths.TweaksCatalog = Join-Path $Global:PhoenixContext.Paths.Catalogs $Global:PhoenixContext.Settings.FileNames.TweaksCatalog
$Global:PhoenixContext.Paths.CleanupCatalog = Join-Path $Global:PhoenixContext.Paths.Catalogs $Global:PhoenixContext.Settings.FileNames.CleanupCatalog
$Global:PhoenixContext.Paths.VscodeConfig = Join-Path $PSScriptRoot $Global:PhoenixContext.Settings.Paths.VscodeConfig

# Cargar el tema de la UI desde el fichero JSON
try {
    $Global:PhoenixContext.Theme = Get-Content -Raw -Path $Global:PhoenixContext.Paths.ThemeFile | ConvertFrom-Json
} catch {
    Write-Warning "No se pudo cargar el fichero de tema desde '$($Global:PhoenixContext.Paths.ThemeFile)'. Usando colores por defecto."
    $Global:PhoenixContext.Theme = @{ Title = "Cyan"; Subtle = "DarkGray"; Step = "White"; SubStep = "Gray"; Success = "Green"; Warn = "Yellow"; Error = "Red"; Consent = "Cyan"; Info = "Gray"; Log = "DarkGray" }
}

try { Stop-Transcript | Out-Null } catch {}
Start-Transcript -Path $Global:PhoenixContext.Paths.LogFile

# SECCIÃ“N 3: CARGA DE MÃ“DULOS
try {
    # Importar el módulo de utilidades primero, ya que otros módulos dependen de él.
    Import-Module (Join-Path $Global:PhoenixContext.Paths.Modules "Phoenix-Utils.psm1") -Force

    # Importar los módulos de fase dinámicamente
    $phaseModules = Get-ChildItem -Path $Global:PhoenixContext.Paths.Modules -Filter "Phase*.psm1" | Sort-Object Name
    foreach ($module in $phaseModules) {
        Write-Host "Cargando módulo: $($module.Name)" -ForegroundColor DarkGray
        Import-Module $module.FullName -Force
    }
} catch {
    Write-Host "[ERROR FATAL] No se pudo cargar un módulo esencial desde la carpeta '$($Global:PhoenixContext.Paths.Modules)'." -ForegroundColor Red
    Write-Host "Error original: $($_.Exception.Message)" -ForegroundColor Red
    Request-Continuation -Message "Presione Enter para salir."
    exit
}

# SECCIÃ“N 3.1: VERIFICACIÃ“N DE CODIFICACIÃ“N DE FICHEROS
Set-FileEncodingToUtf8 -BasePath $Global:PhoenixContext.Paths.Root -Extensions @("*.ps1", "*.psm1", "*.json", "*.md", "*.txt")
Write-Host # Add a newline for spacing

# SECCIÃ“N 3.5: VERIFICACIÃ“N INICIAL DE INTERNET
if (-not (Test-Connection -ComputerName 1.1.1.1 -Count 1 -Quiet)) {
    Write-PhoenixStyledOutput -Type Error -Message "No se pudo establecer una conexión a Internet. El script no puede continuar."
    Request-Continuation -Message "Presione Enter para salir."
    exit
}

# SECCIÃ“N 4: PANTALLA DE BIENVENIDA Y CONSENTIMIENTO
$global:RebootIsPending = $false
Clear-Host
Show-PhoenixHeader -Title "Motor de Aprovisionamiento Fénix v3.1" -NoClear
Write-PhoenixStyledOutput -Type Info -Message "Este script automatiza la configuración y aprovisionamiento de un entorno de desarrollo en Windows."
Write-PhoenixStyledOutput -Type Info -Message "Realizará cambios significativos en el sistema, como instalar/desinstalar software y aplicar optimizaciones."
Write-Host
Write-PhoenixStyledOutput -Type Warn -Message "ADVERTENCIA: Ejecute este script bajo su propio riesgo. Asegúrese de entender lo que hace cada fase."
Write-Host

$consent = Request-MenuSelection -ValidChoices @('S', 'N') -PromptMessage "¿Acepta los riesgos y desea continuar?" -IsYesNoPrompt
if ($consent -ne 'S') {
    Write-PhoenixStyledOutput -Type Error -Message "Consentimiento no otorgado. El script se cerrará."
    Start-Sleep -Seconds 2
    exit
}

# SECCIÃ“N 5: BUCLE DE CONTROL PRINCIPAL
$mainMenuOptions = @(
    @{ Description = "Ejecutar FASE 1: Erradicación de OneDrive"; Action = { Invoke-OneDrivePhase } },
    @{ Description = "Ejecutar FASE 2: Instalación de Software"; Action = { Invoke-SoftwareMenuPhase -CatalogPath $Global:PhoenixContext.Paths.Catalogs } },
    @{ Description = "Ejecutar FASE 3: Optimización del Sistema"; Action = { Invoke-TweaksPhase -CatalogPath $Global:PhoenixContext.Paths.TweaksCatalog } },
    @{ Description = "Ejecutar FASE 4: Instalación de WSL2"; Action = { Invoke-WslPhase } },
    @{ Description = "Ejecutar FASE 5: Limpieza del Sistema"; Action = { Invoke-CleanupPhase -CatalogPath $Global:PhoenixContext.Paths.CleanupCatalog } },
    @{ Description = "Ejecutar FASE 6: Saneamiento y Calidad del Código"; Action = { Invoke-CodeQualityPhase } },
    @{ Description = "Ejecutar FASE 7: Generar Informe de Auditoría"; Action = { Invoke-AuditPhase } }
)

function Show-MainMenu {
    param([array]$menuOptions, [switch]$NoClear)
    Show-PhoenixHeader -Title "Motor de Aprovisionamiento Fénix v3.1" -NoClear:$NoClear
    Write-PhoenixStyledOutput -Type Info -Message "Toda la salida se registrará en: $($Global:PhoenixContext.Paths.LogFile)`n"

    for ($i = 0; $i -lt $menuOptions.Count; $i++) {
        $option = $menuOptions[$i]
        Write-PhoenixStyledOutput -Type Step -Message "[$($i+1)] $($option.Description)"
    }

    Write-PhoenixStyledOutput -Type Step -Message "[R] Refrescar Menú"
    Write-PhoenixStyledOutput -Type Step -Message "[0] Salir"
    Write-Host
}

$exitMainMenu = $false
try {
    $firstRun = $true
    while (-not $exitMainMenu) {
        Show-MainMenu -menuOptions $mainMenuOptions -NoClear:(-not $firstRun)
        $firstRun = $false

        $numericChoices = 1..$mainMenuOptions.Count | ForEach-Object { "$_" }
        $validChoices = @($numericChoices) + @('R', '0')
        $choice = Request-MenuSelection -ValidChoices $validChoices -AllowMultipleSelections:$false
        if ([string]::IsNullOrEmpty($choice)) { continue }


        if ($choice -eq '0') { $exitMainMenu = $true; continue }
        if ($choice -eq 'R') { Clear-Host; continue }

        # Como ya no se permiten selecciones múltiples, la lógica se simplifica.
        $chosenIndex = [int]$choice - 1
        if ($chosenIndex -ge 0 -and $chosenIndex -lt $mainMenuOptions.Count) {
            $chosenOption = $mainMenuOptions[$chosenIndex]
            & $chosenOption.Action
            if ($global:RebootIsPending) {
                Confirm-SystemRestart
                $global:RebootIsPending = $false
            }
        }
    }
} catch [System.Management.Automation.PipelineStoppedException] {
    # Silenciar el error de Ctrl+C, ya que el bloque finally lo manejará.
} catch {
    Write-PhoenixStyledOutput -Type Error -Message "El script ha encontrado un error fatal inesperado y no puede continuar."
    Write-PhoenixStyledOutput -Type Log -Message "Error: $($_.Exception.Message)"
    Request-Continuation -Message "Presione Enter para salir."
} finally {
    Show-PhoenixHeader -Title "PROCESO FINALIZADO" -NoClear
    Write-PhoenixStyledOutput -Type Info -Message "`nEl log completo de la sesión se ha guardado en: $($Global:PhoenixContext.Paths.LogFile)"; Write-Host
    Stop-Transcript
}
