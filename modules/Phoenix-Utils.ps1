<#
.SYNOPSIS
    Módulo de utilidades compartidas para el motor de aprovisionamiento Fénix.
.DESCRIPTION
    Contiene funciones de soporte para la interfaz de usuario (UI), verificaciones
    del entorno y otras tareas comunes, para ser utilizadas por el lanzador y
    todos los módulos de fase.
.NOTES
    Versión: 1.2
    Autor: miguel-cinsfran
#>

# VARIABLES GLOBALES DE ESTILO (CARGADAS UNA VEZ)
$Global:Theme = @{
    Title     = "Cyan"
    Subtle    = "DarkGray"
    Step      = "White"
    SubStep   = "Gray"
    Success   = "Green"
    Warn      = "Yellow"
    Error     = "Red"
    Consent   = "Cyan"
    Info      = "Gray"
    Log       = "DarkGray"
    Control   = @{
        Up        = "$([char]27)[A"
        ClearLine = "$([char]27)[2K"
        ToLineStart = "`r"
    }
}

# FUNCIONES DE UI
function Show-Header {
    param([string]$TitleText)
    $underline = "$([char]27)[4m"; $reset = "$([char]27)[0m"
    Clear-Host
    Write-Host; Write-Host "$underline$TitleText$reset" -F $Global:Theme.Title; Write-Host "---" -F $Global:Theme.Subtle; Write-Host
}

function Write-Styled {
    param([string]$Message, [string]$Type = "Info", [switch]$NoNewline)
    $prefixMap = @{ Step="  -> "; SubStep="     - "; Success=" [ÉXITO] "; Warn=" [OMITIDO] "; Error=" [ERROR] "; Log="       | " }
    $prefix = $prefixMap[$Type]
    if ($NoNewline) { Write-Host "$prefix$Message" -F $Global:Theme[$Type] -NoNewline }
    else { Write-Host "$prefix$Message" -F $Global:Theme[$Type] }
}

function Pause-And-Return {
    param([string]$Message = "`nPresione Enter para continuar...")
    Write-Styled -Type Consent -Message $Message -NoNewline
    Read-Host | Out-Null
}

function Invoke-MenuPrompt {
    param(
        [string]$PromptMessage = "Seleccione una opción",
        [string[]]$ValidChoices
    )
    
    try {
        while ($true) {
            # Usar Read-Host con -Prompt es más robusto que Write-Host -NoNewline
            $input = (Read-Host -Prompt "  -> $PromptMessage").Trim().ToUpper()

            if ($ValidChoices -contains $input) {
                return $input
            }

            # La manipulación del cursor con ANSI es frágil. Un mensaje de error simple es más seguro.
            Write-Host "`n [ERROR] Opción no válida. Por favor, intente de nuevo." -ForegroundColor $Global:Theme.Error
            Start-Sleep -Seconds 2

            # Limpiar las líneas de error y el prompt anterior para la siguiente iteración
            $up = $Global:Theme.Control.Up
            $clear = $Global:Theme.Control.ClearLine
            Write-Host "${up}${clear}${up}${clear}" -NoNewline
        }
    } catch [System.Management.Automation.PipelineStoppedException] {
        # Capturada por el manejador de Ctrl+C del lanzador, simplemente re-lanzar.
        throw
    }
}

function Invoke-JobWithTimeout {
    param(
        [scriptblock]$ScriptBlock,
        [int]$TimeoutSeconds = 120,
        [string]$Activity = "Ejecutando operación en segundo plano..."
    )

    $job = Start-Job -ScriptBlock $ScriptBlock
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $timeout = New-TimeSpan -Seconds $TimeoutSeconds

    while ($job.State -eq 'Running' -and $timer.Elapsed -lt $timeout) {
        Write-Progress -Activity $Activity -Status "Tiempo restante: $(($timeout - $timer.Elapsed).ToString('mm\:ss'))" -PercentComplete (($timer.Elapsed.TotalSeconds / $TimeoutSeconds) * 100)
        Start-Sleep -Milliseconds 250
    }
    Write-Progress -Activity $Activity -Completed

    $result = [PSCustomObject]@{
        Success = $false
        Output = @()
        Error = ""
    }

    if ($job.State -eq 'Running') {
        $result.Error = "La operación excedió el tiempo de espera de $TimeoutSeconds segundos y fue terminada."
        Stop-Job $job -Force
    }
    elseif ($job.State -eq 'Failed') {
        $result.Error = ($job.Error | Select-Object -First 1).Exception.Message
    }
    else {
        $result.Success = $true
    }

    $result.Output = Receive-Job $job
    Remove-Job $job -Force
    return $result
}


# FUNCIONES DE VERIFICACIÓN DEL ENTORNO
function Invoke-PreFlightChecks {
    Show-Header -Title "FASE 0: Verificación de Requisitos del Entorno"
    
    Write-Styled -Message "Verificando conectividad a Internet..." -NoNewline
    if (-not (Test-Connection -ComputerName 1.1.1.1 -Count 1 -Quiet)) {
        Write-Host " [ERROR]" -F $Global:Theme.Error
        Write-Styled -Type Error -Message "No se pudo establecer una conexión a Internet. El script no puede continuar."
        Read-Host "Presione Enter para salir."
        exit
    }
    Write-Host " [ÉXITO]" -F $Global:Theme.Success
    Write-Styled -Message "Verificando existencia de Chocolatey..." -NoNewline
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Write-Host " [NO ENCONTRADO]" -F $Global:Theme.Warn
        Write-Styled -Type Consent -Message "El gestor de paquetes Chocolatey no está instalado y es requerido."
        if ((Read-Host "¿Desea que el script intente instalarlo ahora? (S/N)").Trim().ToUpper() -eq 'S') {
            Write-Styled -Type Info -Message "Instalando Chocolatey... Esto puede tardar unos minutos."
            try {
                Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
                Write-Styled -Type Success -Message "Chocolatey se ha instalado correctamente."
                Write-Styled -Type Info -Message "Se recomienda cerrar y volver a abrir esta terminal para asegurar que el PATH se actualice."
                Pause-And-Return
            } catch {
                Write-Styled -Type Error -Message "La instalación automática de Chocolatey falló."
                Write-Styled -Type Log -Message "Error: $($_.Exception.Message)"
                Read-Host "Presione Enter para salir."
                exit
            }
        } else {
            Write-Styled -Type Error -Message "Instalación de dependencia denegada. El script no puede continuar."
            Read-Host "Presione Enter para salir."
            exit
        }
    } else {
        Write-Host " [ÉXITO]" -F $Global:Theme.Success
    }
    Write-Styled -Message "Verificando existencia de Winget..." -NoNewline
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host " [NO ENCONTRADO]" -F $Global:Theme.Warn
        Write-Styled -Type Error -Message "El gestor de paquetes Winget no fue encontrado. Por favor, actualice su 'App Installer' desde la Microsoft Store."
        Read-Host "Presione Enter para salir."
        exit
    } else {
        Write-Host " [ÉXITO]" -F $Global:Theme.Success
    }
    Pause-And-Return -Message "Verificaciones completadas. Presione Enter para continuar..."
}