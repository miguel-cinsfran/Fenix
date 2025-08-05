<#
.SYNOPSIS
    Orquestador central para el motor de aprovisionamiento Fénix.
.DESCRIPTION
    Este script es el único punto de entrada. Carga los módulos de fase, gestiona el estado
    global (con persistencia inteligente), el menú principal, el logging y el manejo de interrupciones.
.NOTES
    Versión: 1.2
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
$workspacePath = Join-Path $PSScriptRoot "workspace"
$logFile = Join-Path $PSScriptRoot "Provision-Log-Phoenix-$((Get-Date).ToString('yyyyMMdd-HHmmss')).txt"
$stateFile = Join-Path $workspacePath "phoenix_state.json"

if (-not (Test-Path $workspacePath)) {
    New-Item -Path $workspacePath -ItemType Directory -Force | Out-Null
}

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

# SECCIÓN 3.5: VERIFICACIONES PREVIAS DEL ENTORNO
Invoke-PreFlightChecks

# SECCIÓN 4: INICIALIZACIÓN DE ESTADO
function New-CleanState {
    return [PSCustomObject]@{
        OneDriveErradicated = $false
        SoftwareInstalled   = $false
        TweaksApplied       = $false
        WSLInstalled        = $false
        CleanupPerformed    = $false
        FatalErrorOccurred  = $false
        ManualActions       = [System.Collections.Generic.List[string]]::new()
    }
}
$state = New-CleanState

if (Test-Path $stateFile) {
    try {
        $loadedState = Get-Content -Path $stateFile -Raw | ConvertFrom-Json
        Show-Header -Title "Sesión Anterior Detectada"
        if ($loadedState.FatalErrorOccurred) {
            Write-Styled -Type Warn -Message "Se ha detectado una sesión anterior que terminó con un ERROR FATAL."
            Write-Styled -Type Consent -Message "Se recomienda empezar una sesión limpia para evitar problemas."
        } else {
            Write-Styled -Type Info -Message "Se ha detectado una sesión anterior sin errores."
            Write-Styled -Type Consent -Message "Puede continuar la sesión o empezar una nueva."
        }
        Write-Styled -Type Step -Message "`n[1] Continuar con la sesión anterior."
        Write-Styled -Type Step -Message "[2] Empezar una sesión limpia (elimina el estado guardado)."
        $userChoice = Read-Host "`nSeleccione una opción"
        if ($userChoice -eq '2') {
            Write-Styled -Type Info -Message "Eliminando estado anterior y comenzando de nuevo..."
            Remove-Item $stateFile -Force
            # state ya es un estado limpio, no se necesita acción
        } else {
            Write-Styled -Type Info -Message "Restaurando y fusionando sesión anterior..."
            # Fusionar el estado cargado con un estado limpio para garantizar que todas las propiedades existan.
            # Esto proporciona compatibilidad hacia adelante si se añaden nuevas propiedades al estado.
            foreach ($prop in $loadedState.PSObject.Properties) {
                if ($state.PSObject.Properties.Match($prop.Name)) {
                    $state.($prop.Name) = $prop.Value
                }
            }
        }

        # Asegurar que ManualActions sea siempre una lista genérica para evitar errores de tipo.
        if ($state.ManualActions -and $state.ManualActions.GetType().Name -ne 'List`1') {
            $state.ManualActions = [System.Collections.Generic.List[string]]::new($state.ManualActions)
        }
        Start-Sleep -Seconds 2
    } catch {
        Write-Styled -Type Warn -Message "El archivo de estado '$stateFile' está corrupto. Empezando con un estado limpio."
        $state = New-CleanState
        Start-Sleep -Seconds 2
    }
}

# SECCIÓN 5: BUCLE DE CONTROL PRINCIPAL (ARQUITECTURA GUIADA POR DATOS)
$mainMenuOptions = @(
    [PSCustomObject]@{
        Description = "Ejecutar FASE 1: Erradicación de OneDrive"
        Action = { 
            param($s) 
            $s = Invoke-Phase1_OneDrive -state $s
            Pause-And-Return -Message "Presione Enter para volver al menú principal..."
            return $s
        }
        StatusCheck = { param($s) $s.OneDriveErradicated }
    },
    [PSCustomObject]@{
        Description = "Ejecutar FASE 2: Instalación de Software"
        Action = { param($s) Invoke-Phase2_SoftwareMenu -state $s -CatalogPath $catalogsPath }
        StatusCheck = { param($s) $s.SoftwareInstalled }
    },
    [PSCustomObject]@{
        Description = "Ejecutar FASE 3: Optimización del Sistema"
        Action = { 
            param($s) 
            $s = Invoke-Phase3_Tweaks -state $s -CatalogPath $tweaksCatalog
            Pause-And-Return -Message "Presione Enter para volver al menú principal..."
            return $s
        }
        StatusCheck = { param($s) $s.TweaksApplied }
    },
    [PSCustomObject]@{
        Description = "Ejecutar FASE 4: Instalación de WSL2"
        Action = {
            param($s)
            $s = Invoke-Phase4_WSL -state $s
            return $s
        }
        StatusCheck = { param($s) $s.WSLInstalled }
    },
    [PSCustomObject]@{
        Description = "Ejecutar FASE 5: Limpieza del Sistema"
        Action = {
            param($s)
            $s = Invoke-Phase5_Cleanup -state $s -CatalogPath $catalogsPath
            return $s
        }
        StatusCheck = { param($s) $s.CleanupPerformed }
    }
)

function Show-MainMenu {
    param(
        [PSCustomObject]$currentState,
        [array]$menuOptions,
        [switch]$NoClear
    )
    Show-Header -Title "Motor de Aprovisionamiento Fénix v2.7" -NoClear:$NoClear
    Write-Styled -Type Info -Message "Toda la salida se registrará en: $logFile`n"
    
    for ($i = 0; $i -lt $menuOptions.Count; $i++) {
        $option = $menuOptions[$i]
        $isCompleted = & $option.StatusCheck -s $currentState
        $statusString = if ($isCompleted) { "[COMPLETADO]" } elseif ($currentState.FatalErrorOccurred) { "[FALLIDO]" } else { "[PENDIENTE]" }
        Write-Styled -Type Step -Message "[$($i+1)] $($option.Description) $statusString"
    }
    
    Write-Styled -Type Step -Message "[R] Refrescar Menú"
    Write-Styled -Type Step -Message "[Q] Salir"
    Write-Host
}

Clear-Host
Write-Styled -Type Title -Message "ADVERTENCIA Y CONSENTIMIENTO"
Write-Styled -Type Info -Message "Este script realizará cambios significativos en el sistema, incluyendo la eliminación`nde software y la instalación de nuevos paquetes como Administrador."
Write-Host
if ((Read-Host -Prompt "Escriba 'ACEPTO' para confirmar que entiende los riesgos y desea continuar").Trim().ToUpper() -ne 'ACEPTO') {
    Write-Styled -Type Error -Message "Consentimiento no otorgado. El script se cerrará."
    Start-Sleep -Seconds 2
    exit
}

$exitMainMenu = $false
try {
    $firstRun = $true
    while (-not $exitMainMenu) {
        # En la primera ejecución, el menú se muestra sin limpiar (ya que la pantalla está limpia).
        # En las siguientes, no se limpia para evitar el parpadeo, excepto si se refresca.
        Show-MainMenu -currentState $state -menuOptions $mainMenuOptions -NoClear:(-not $firstRun)
        $firstRun = $false
        
        if ($state.FatalErrorOccurred) {
            Write-Styled -Type Error -Message "Un error fatal ocurrió en una fase anterior. El script no puede continuar con nuevas operaciones."
            Write-Styled -Type Consent -Message "Presione Q para salir."
        }

        $numericChoices = 1..$mainMenuOptions.Count
        $validChoices = @($numericChoices) + @('R', 'Q')
        $choice = Invoke-MenuPrompt -ValidChoices $validChoices

        switch ($choice) {
            'R' { Clear-Host; continue } # Limpiar solo al refrescar
            'Q' { $exitMainMenu = $true; continue }
            default {
                $chosenIndex = [int]$choice - 1
                $chosenOption = $mainMenuOptions[$chosenIndex]
                
                $state = & $chosenOption.Action -s $state
                $state | ConvertTo-Json -Depth 5 | Out-File -FilePath $stateFile -Encoding utf8
            }
        }
    }
} catch [System.Management.Automation.PipelineStoppedException] {
    # Silenciar el error de Ctrl+C, ya que el bloque finally lo manejará.
} catch {
    # En caso de un error verdaderamente inesperado, marcar el estado como fallido si es posible.
    if ($state -is [PSCustomObject]) {
        $state.FatalErrorOccurred = $true
    }
    Write-Styled -Type Error -Message "El script ha encontrado un error fatal inesperado y no puede continuar."
    Write-Styled -Type Log -Message "Error: $($_.Exception.Message)"
    Read-Host "Presione Enter para salir."
} finally {
    # --- Bloque de finalización a prueba de fallos ---
    # Asegurarse de que el estado exista y sea un objeto antes de intentar usarlo.
    if ($state -is [PSCustomObject]) {
        if (-not $exitMainMenu -and -not $state.FatalErrorOccurred) {
            Write-Host "`nInterrupción del usuario (Ctrl+C) detectada. Procediendo a la finalización ordenada..." -F $Theme.Warn
        }

        # Guardar el estado final solo si el objeto es válido.
        try {
            $state | ConvertTo-Json -Depth 5 | Out-File -FilePath $stateFile -Encoding utf8
        } catch {
            Write-Styled -Type Error -Message "No se pudo guardar el archivo de estado final: $($_.Exception.Message)"
        }

        Show-Header -Title "PROCESO FINALIZADO" -NoClear
        if ($state.FatalErrorOccurred) { Write-Styled -Type Error -Message "`nLa ejecución fue abortada o finalizó con errores. Revise el log." }

        # Comprobar la existencia y el tipo de ManualActions antes de acceder a Count
        if ($state.PSObject.Properties.Name -contains 'ManualActions' -and $state.ManualActions -is [System.Collections.Generic.List[string]] -and $state.ManualActions.Count -gt 0) {
            Write-Styled -Type Consent -Message "[ACCIONES MANUALES REQUERIDAS]"; Write-Host ""
            ($state.ManualActions | Get-Unique) | ForEach-Object { Write-Styled -Type Step -Message $_ }
            Write-Host ""; Write-Host "---" -F $Theme.Subtle
        } elseif (-not $state.FatalErrorOccurred) {
            Write-Styled -Type Success -Message "No hay acciones manuales requeridas."
        }
    } else {
        # Caso extremo donde $state no es un objeto válido.
        Show-Header -Title "PROCESO FINALIZADO CON ERRORES GRAVES" -NoClear
        Write-Styled -Type Error -Message "El estado interno del script se corrompió y no se pudo finalizar limpiamente."
    }

    Write-Styled -Type Info -Message "`nEl log completo de la sesión se ha guardado en: $logFile"; Write-Host
    Stop-Transcript
}