<#
.SYNOPSIS
    Orquestador central para el motor de aprovisionamiento Fénix.
.DESCRIPTION
    Este script es el único punto de entrada. Carga los módulos de fase, gestiona el estado
    global (con persistencia inteligente), el menú principal, el logging y el manejo de interrupciones.
.NOTES
    Versión: 3.3
    Autor: miguel-cinsfran
    Requiere: Privilegios de Administrador. Estructura de directorios modular.
#>

# SECCIÓN 0: CONFIGURACIÓN DE CODIFICACIÓN UNIVERSAL
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# SECCIÓN 1: AUTO-ELEVACIÓN DE PRIVILEGIOS
if (-not ([System.Security.Principal.WindowsPrincipal][System.Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "Se requieren privilegios de Administrador. Relanzando..."
    Start-Process powershell -Verb RunAs -ArgumentList "-File `"$($myinvocation.mycommand.definition)`""
    exit
}

# SECCIÓN 2: CARGA DE CONFIGURACIÓN Y DEFINICIÓN DE RUTAS
try {
    $configFile = Join-Path $PSScriptRoot "settings.psd1"
    $Global:Settings = Import-PowerShellDataFile -Path $configFile
} catch {
    Write-Error "No se pudo cargar el fichero de configuración 'settings.psd1'. El script no puede continuar."
    Request-Continuation -Message "Presione Enter para salir."; exit
}

# Construir rutas absolutas basadas en la configuración
$modulesPath = Join-Path $PSScriptRoot $Global:Settings.Paths.Modules
$catalogsPath = Join-Path $PSScriptRoot $Global:Settings.Paths.Catalogs
$logPath = Join-Path $PSScriptRoot $Global:Settings.Paths.Logs
$logFile = Join-Path $logPath "$($Global:Settings.FileNames.LogBaseName)-$((Get-Date).ToString('yyyyMMdd-HHmmss')).txt"
$themeFile = Join-Path $PSScriptRoot (Join-Path $Global:Settings.Paths.Themes $Global:Settings.FileNames.Theme)
$tweaksCatalog = Join-Path $catalogsPath $Global:Settings.FileNames.TweaksCatalog
$cleanupCatalog = Join-Path $catalogsPath $Global:Settings.FileNames.CleanupCatalog

# Cargar el tema de la UI desde el fichero JSON
try {
    $Global:Theme = Get-Content -Raw -Path $themeFile | ConvertFrom-Json
} catch {
    Write-Warning "No se pudo cargar el fichero de tema desde '$themeFile'. Usando colores por defecto."
    $Global:Theme = @{ Title = "Cyan"; Subtle = "DarkGray"; Step = "White"; SubStep = "Gray"; Success = "Green"; Warn = "Yellow"; Error = "Red"; Consent = "Cyan"; Info = "Gray"; Log = "DarkGray" }
}

try { Stop-Transcript | Out-Null } catch {}
Start-Transcript -Path $logFile

# SECCIÓN 3: CARGA DE MÓDULOS
try {
    # Importar el módulo de utilidades primero, ya que otros módulos dependen de él.
    Import-Module (Join-Path $modulesPath "Phoenix-Utils.psm1") -Force

    # Importar los módulos de fase dinámicamente
    $phaseModules = Get-ChildItem -Path $modulesPath -Filter "Phase*.psm1" | Sort-Object Name
    foreach ($module in $phaseModules) {
        Write-Host "Cargando módulo: $($module.Name)" -ForegroundColor DarkGray
        Import-Module $module.FullName -Force
    }
} catch {
    Write-Host "[ERROR FATAL] No se pudo cargar un módulo esencial desde la carpeta '$modulesPath'." -ForegroundColor Red
    Write-Host "Error original: $($_.Exception.Message)" -ForegroundColor Red
    Request-Continuation -Message "Presione Enter para salir."
    exit
}

# SECCIÓN 3.1: VERIFICACIÓN DE CODIFICACIÓN DE FICHEROS
# Esta función ahora es parte del módulo de utilidades y debería estar disponible.
Set-FileEncodingToUtf8 -BasePath $PSScriptRoot -Extensions @("*.ps1", "*.psm1", "*.json", "*.md", "*.txt")
Write-Host # Add a newline for spacing

# SECCIÓN 3.5: VERIFICACIÓN INICIAL DE INTERNET
if (-not (Test-Connection -ComputerName 1.1.1.1 -Count 1 -Quiet)) {
    Write-PhoenixStyledOutput -Type Error -Message "No se pudo establecer una conexión a Internet. El script no puede continuar."
    Request-Continuation -Message "Presione Enter para salir."
    exit
}

# SECCIÓN 4: PANTALLA DE BIENVENIDA Y CONSENTIMIENTO
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

# SECCIÓN 5: BUCLE DE CONTROL PRINCIPAL
$mainMenuOptions = @(
    @{ Description = "Ejecutar FASE 1: Erradicación de OneDrive"; Action = { Invoke-OneDrivePhase } },
    @{ Description = "Ejecutar FASE 2: Instalación de Software"; Action = { Invoke-SoftwareMenuPhase -CatalogPath $catalogsPath } },
    @{ Description = "Ejecutar FASE 3: Optimización del Sistema"; Action = { Invoke-TweaksPhase -CatalogPath $tweaksCatalog } },
    @{ Description = "Ejecutar FASE 4: Instalación de WSL2"; Action = { Invoke-WslPhase } },
    @{ Description = "Ejecutar FASE 5: Limpieza del Sistema"; Action = { Invoke-CleanupPhase -CatalogPath $cleanupCatalog } },
    @{ Description = "Ejecutar FASE 6: Saneamiento y Calidad del Código"; Action = { Invoke-CodeQualityPhase } },
    @{ Description = "Ejecutar FASE 7: Generar Informe de Auditoría"; Action = { Invoke-AuditPhase } }
)

function Show-MainMenu {
    param([array]$menuOptions, [switch]$NoClear)
    Show-PhoenixHeader -Title "Motor de Aprovisionamiento Fénix v3.1" -NoClear:$NoClear
    Write-PhoenixStyledOutput -Type Info -Message "Toda la salida se registrará en: $logFile`n"

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
    Write-PhoenixStyledOutput -Type Info -Message "`nEl log completo de la sesión se ha guardado en: $logFile"; Write-Host
    Stop-Transcript
}
