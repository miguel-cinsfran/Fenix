<#
.SYNOPSIS
    Orquestador central para el motor de aprovisionamiento Fénix.
.DESCRIPTION
    Este script es el único punto de entrada. Carga los módulos de fase, gestiona el estado
    global (con persistencia inteligente), el menú principal, el logging y el manejo de interrupciones.
.NOTES
    Versión: 1.5
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

# SECCIÓN 2: DEFINICIÓN DE RUTAS Y LOGGING
$modulesPath = Join-Path $PSScriptRoot "modules"
$assetsPath = Join-Path $PSScriptRoot "assets"
$catalogsPath = Join-Path $assetsPath "catalogs"
$tweaksCatalog = Join-Path $assetsPath "catalogs/system_tweaks.json"
$logFile = Join-Path $PSScriptRoot "Provision-Log-Phoenix-$((Get-Date).ToString('yyyyMMdd-HHmmss')).txt"

try { Stop-Transcript | Out-Null } catch {}
Start-Transcript -Path $logFile

# SECCIÓN 3: CARGA DE MÓDULOS (DOT-SOURCING)
try {
    . (Join-Path $modulesPath "Phoenix-Utils.ps1")
    . (Join-Path $modulesPath "Phase1-OneDrive.ps1")
    . (Join-Path $modulesPath "Phase2-Software.ps1")
    . (Join-Path $modulesPath "Phase3-Tweaks.ps1")
    . (Join-Path $modulesPath "Phase4-WSL.ps1")
    . (Join-Path $modulesPath "Phase5-Cleanup.ps1")
} catch {
    Write-Host "[ERROR FATAL] No se pudo cargar un módulo esencial desde la carpeta '$modulesPath'." -F Red
    Write-Host "Error original: $($_.Exception.Message)" -F Red
    Read-Host "Presione Enter para salir."
    exit
}

# SECCIÓN 3.5: VERIFICACIÓN INICIAL DE INTERNET
if (-not (Test-Connection -ComputerName 1.1.1.1 -Count 1 -Quiet)) {
    Write-Styled -Type Error -Message "No se pudo establecer una conexión a Internet. El script no puede continuar."
    Read-Host "Presione Enter para salir."
    exit
}

# SECCIÓN 4: PANTALLA DE BIENVENIDA Y CONSENTIMIENTO
$global:RebootIsPending = $false
Clear-Host
Show-Header -Title "Motor de Aprovisionamiento Fénix v3.0" -NoClear
Write-Styled -Type Info -Message "Este script automatiza la configuración y aprovisionamiento de un entorno de desarrollo en Windows."
Write-Styled -Type Info -Message "Realizará cambios significativos en el sistema, como instalar/desinstalar software y aplicar optimizaciones."
Write-Host
Write-Styled -Type Warn -Message "ADVERTENCIA: Ejecute este script bajo su propio riesgo. Asegúrese de entender lo que hace cada fase."
Write-Host

$consent = Invoke-MenuPrompt -ValidChoices @('S', 'N') -PromptMessage "¿Acepta los riesgos y desea continuar? (S/N)"
if ($consent -ne 'S') {
    Write-Styled -Type Error -Message "Consentimiento no otorgado. El script se cerrará."
    Start-Sleep -Seconds 2
    exit
}

# SECCIÓN 5: BUCLE DE CONTROL PRINCIPAL (SIMPLIFICADO)
$mainMenuOptions = @(
    @{ Description = "Ejecutar FASE 1: Erradicación de OneDrive"; Action = { Invoke-Phase1_OneDrive; Pause-And-Return } },
    @{ Description = "Ejecutar FASE 2: Instalación de Software"; Action = { Invoke-Phase2_SoftwareMenu -CatalogPath $catalogsPath } },
    @{ Description = "Ejecutar FASE 3: Optimización del Sistema"; Action = { Invoke-Phase3_Tweaks -CatalogPath $tweaksCatalog; Pause-And-Return } },
    @{ Description = "Ejecutar FASE 4: Instalación de WSL2"; Action = { Invoke-Phase4_WSL } },
    @{ Description = "Ejecutar FASE 5: Limpieza del Sistema"; Action = { Invoke-Phase5_Cleanup -CatalogPath $catalogsPath } }
)

function Show-MainMenu {
    param([array]$menuOptions, [switch]$NoClear)
    Show-Header -Title "Motor de Aprovisionamiento Fénix v3.0" -NoClear:$NoClear
    Write-Styled -Type Info -Message "Toda la salida se registrará en: $logFile`n"
    
    for ($i = 0; $i -lt $menuOptions.Count; $i++) {
        $option = $menuOptions[$i]
        Write-Styled -Type Step -Message "[$($i+1)] $($option.Description)"
    }
    
    Write-Styled -Type Step -Message "[R] Refrescar Menú"
    Write-Styled -Type Step -Message "[Q] Salir"
    Write-Host
}

$exitMainMenu = $false
try {
    $firstRun = $true
    while (-not $exitMainMenu) {
        Show-MainMenu -menuOptions $mainMenuOptions -NoClear:(-not $firstRun)
        $firstRun = $false
        
        $numericChoices = 1..$mainMenuOptions.Count
        $validChoices = @($numericChoices) + @('R', 'Q')
        $choice = Invoke-MenuPrompt -ValidChoices $validChoices

        switch ($choice) {
            'R' { Clear-Host; continue }
            'Q' { $exitMainMenu = $true; continue }
            default {
                $chosenIndex = [int]$choice - 1
                $chosenOption = $mainMenuOptions[$chosenIndex]
                & $chosenOption.Action
                if ($global:RebootIsPending) {
                    Invoke-RestartPrompt
                    $global:RebootIsPending = $false
                }
            }
        }
    }
} catch [System.Management.Automation.PipelineStoppedException] {
    # Silenciar el error de Ctrl+C, ya que el bloque finally lo manejará.
} catch {
    Write-Styled -Type Error -Message "El script ha encontrado un error fatal inesperado y no puede continuar."
    Write-Styled -Type Log -Message "Error: $($_.Exception.Message)"
    Read-Host "Presione Enter para salir."
} finally {
    Show-Header -Title "PROCESO FINALIZADO" -NoClear
    Write-Styled -Type Info -Message "`nEl log completo de la sesión se ha guardado en: $logFile"; Write-Host
    Stop-Transcript
}