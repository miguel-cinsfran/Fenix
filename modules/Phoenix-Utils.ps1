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
}

# FUNCIONES DE UI
function Show-Header {
    param(
        [string]$TitleText,
        [switch]$NoClear
    )
    $underline = "$([char]27)[4m"; $reset = "$([char]27)[0m"
    if (-not $NoClear) { Clear-Host }
    Write-Host; Write-Host "$underline$TitleText$reset" -F $Global:Theme.Title; Write-Host "---" -F $Global:Theme.Subtle; Write-Host
}

function Write-Styled {
    param([string]$Message, [string]$Type = "Info", [switch]$NoNewline)
    $prefixMap = @{ Step="  -> "; SubStep="     - "; Success=" [ÉXITO] "; Warn=" [OMITIDO] "; Error=" [ERROR] "; Log="       | " }
    $prefix = $prefixMap[$Type]
    if ($NoNewline) { Write-Host "$prefix$Message" -F $Global:Theme[$Type] -NoNewline }
    else { Write-Host "$prefix$Message" -F $Global:Theme[$Type] }
}

function Invoke-StandardMenu {
    param(
        [string]$Title,
        [array]$MenuItems,
        $ActionOptions,
        [string]$PromptMessage = "Seleccione una opción"
    )
    Show-Header -Title $Title

    # Display menu items (numeric choices)
    for ($i = 0; $i -lt $MenuItems.Count; $i++) {
        $item = $MenuItems[$i]
        # Default values
        $icon = "[ ]"
        $color = $Global:Theme.Step
        $statusText = ""

        if ($item.Status) {
            $statusText = "- $($item.Status)"
            switch ($item.Status) {
                'Aplicado'                { $icon = "[✓]"; $color = $Global:Theme.Success }
                'Actualización Disponible' { $icon = "[↑]"; $color = $Global:Theme.Warn }
                'Instalado'               { $icon = "[✓]"; $color = $Global:Theme.Success }
                'Pendiente'               { $icon = "[ ]"; $color = $Global:Theme.Warn }
                'Aplicado (No Reversible)'{ $icon = "[✓]"; $color = $Global:Theme.Info }
            }
        }

        $line = "{0,-4} {1,2}. {2,-55} {3}" -f $icon, ($i + 1), $item.Description, $statusText
        Write-Host $line -ForegroundColor $color
    }
    Write-Host

    # Display action options (letter choices)
    $validChoices = @() + (1..$MenuItems.Count)
    foreach ($key in $ActionOptions.Keys) {
        Write-Styled -Type Consent -Message "-> [$key] $($ActionOptions[$key])"
        $validChoices += $key
    }

    return Invoke-MenuPrompt -ValidChoices $validChoices -PromptMessage $PromptMessage
}

function Pause-And-Return {
    param([string]$Message = "`nPresione Enter para continuar...")
    Write-Styled -Type Consent -Message $Message -NoNewline
    Read-Host | Out-Null
}

function Invoke-RestartPrompt {
    Write-Styled -Type Warn -Message "Se requiere un reinicio para aplicar completamente los cambios."
    if ((Invoke-MenuPrompt -ValidChoices @('S','N') -PromptMessage "Desea reiniciar el equipo ahora?") -eq 'S') {
        Write-Styled -Type Info -Message "Reiniciando el equipo en 5 segundos..."
        Start-Sleep -Seconds 5
        Restart-Computer -Force
    } else {
        Write-Styled -Type Warn -Message "ACCIÓN MANUAL REQUERIDA: Por favor, reinicie el equipo lo antes posible."
    }
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

            # En lugar de manipular el cursor, simplemente se muestra un error. El bucle
            # principal que llama al menú (ej. en el Launcher) se encargará de redibujar
            # la pantalla, o el siguiente prompt aparecerá en una nueva línea.
            Write-Styled -Type Error -Message "Opción no válida. Por favor, inténtelo de nuevo."
            # Una pequeña pausa para que el usuario pueda leer el error.
            Start-Sleep -Seconds 1
            # Se necesita una línea en blanco para separar el error del siguiente prompt
            Write-Host
        }
    } catch [System.Management.Automation.PipelineStoppedException] {
        # Capturada por el manejador de Ctrl+C del lanzador, simplemente re-lanzar.
        throw
    }
}

function Invoke-JobWithTimeout {
    param(
        [scriptblock]$ScriptBlock,
        [string]$Activity = "Ejecutando operación en segundo plano...",
        [int]$TimeoutSeconds = 3600,
        [boolean]$IdleTimeoutEnabled = $true,
        [int]$IdleTimeoutSeconds = 300
    )

    $job = Start-Job -ScriptBlock $ScriptBlock
    $overallTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $overallTimeout = New-TimeSpan -Seconds $TimeoutSeconds
    $idleTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $idleTimeout = New-TimeSpan -Seconds $IdleTimeoutSeconds

    $outputBuffer = New-Object System.Text.StringBuilder
    $lastProgressPercent = -1

    Write-Styled -Type Info -Message "Iniciando tarea: $Activity"

    while ($job.State -eq 'Running') {
        # --- Timeouts ---
        if ($overallTimer.Elapsed -gt $overallTimeout) { Stop-Job $job; throw "La operación '$Activity' excedió el tiempo límite total de $TimeoutSeconds segundos." }
        if ($IdleTimeoutEnabled -and $idleTimer.Elapsed -gt $idleTimeout) { Stop-Job $job; throw "La operación '$Activity' no mostró actividad por más de $IdleTimeoutSeconds segundos y fue terminada." }

        # --- Recibir y procesar nueva salida ---
        $newData = $job.ChildJobs[0].Output.ReadAll()
        if ($newData) {
            $idleTimer.Restart() # Reiniciar temporizador de inactividad
            [void]$outputBuffer.Append($newData -join [System.Environment]::NewLine)

            # --- Lógica de parseo de progreso ---
            $lastLine = ($newData | Where-Object { $_ -match '(\d+)\s*%' } | Select-Object -Last 1)
            if ($lastLine) {
                $percent = -1
                # Patrón para Chocolatey: "Progress: 25%"
                if ($lastLine -match "Progress:\s*(\d+)%") {
                    $percent = [int]$matches[1]
                }
                # Patrón para Winget y otros: "██████████ 100%"
                elseif ($lastLine -match "\s(\d+)\s*%") {
                    $percent = [int]$matches[1]
                }

                if ($percent -ne -1 -and $percent -ne $lastProgressPercent) {
                    $lastProgressPercent = $percent
                    $statusMessage = "Progreso: ${percent}% | Tiempo: $($overallTimer.Elapsed.ToString('hh\:mm\:ss'))"
                    Write-Progress -Activity $Activity -Status $statusMessage -PercentComplete $percent
                }
            }
        }

        # --- Actualización de la barra de progreso (si no hay porcentaje) ---
        if ($lastProgressPercent -lt 0) {
            $status = "Tiempo transcurrido: $($overallTimer.Elapsed.ToString('hh\:mm\:ss'))"
            if ($IdleTimeoutEnabled) {
                $status += " | Tiempo de inactividad restante: $(($idleTimeout - $idleTimer.Elapsed).ToString('mm\:ss'))"
            }
            Write-Progress -Activity $Activity -Status $status
        }

        Start-Sleep -Milliseconds 250
    }

    Write-Progress -Activity $Activity -Completed

    # --- Recopilar resultados finales ---
    $result = [PSCustomObject]@{ Success = $false; Output = @(); Error = "" }
    if ($job.State -eq 'Failed') {
        $errorRecord = $job.ChildJobs[0].Error.ReadAll() | Select-Object -First 1
        $result.Error = $errorRecord.Exception.Message
    } else {
        $result.Success = $true
    }

    # Añadir cualquier salida que no se haya capturado en el bucle
    $remainingOutput = Receive-Job $job
    if ($remainingOutput) {
        [void]$outputBuffer.Append($remainingOutput -join [System.Environment]::NewLine)
    }
    $result.Output = $outputBuffer.ToString().Split([System.Environment]::NewLine)
    Remove-Job $job -Force
    return $result
}

function Invoke-ProtectedRegistryAction {
    param(
        [string]$KeyPath,
        [scriptblock]$Action
    )
    if (-not (Test-Path $KeyPath)) {
        try {
            New-Item -Path $KeyPath -Force -ErrorAction Stop | Out-Null
        } catch {
            throw "No se pudo crear la clave de registro requerida en '$KeyPath': $($_.Exception.Message)"
        }
    }

    $originalSddl = (Get-Acl -Path $KeyPath).Sddl
    try {
        $acl = Get-Acl -Path $KeyPath
        $administratorsSid = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
        $acl.SetOwner($administratorsSid)
        $rule = New-Object System.Security.AccessControl.RegistryAccessRule($administratorsSid, "FullControl", "Allow")
        $acl.AddAccessRule($rule)
        Set-Acl -Path $KeyPath -AclObject $acl -ErrorAction Stop

        # Execute the provided action
        & $Action
    }
    finally {
        # Restore original permissions
        if ($originalSddl) {
            try {
                $restoredAcl = New-Object System.Security.AccessControl.RegistrySecurity
                $restoredAcl.SetSecurityDescriptorSddlForm($originalSddl)
                Set-Acl -Path $KeyPath -AclObject $restoredAcl -ErrorAction Stop
            } catch {
                Write-Styled -Type Error -Message "FALLO CRÍTICO al restaurar permisos en '$KeyPath'. Se requiere intervención manual."
            }
        }
    }
}


function Invoke-NativeCommand {
    param(
        [string]$Executable,
        [string]$ArgumentList,
        [string[]]$FailureStrings,
        [string]$Activity,
        [boolean]$IdleTimeoutEnabled = $true
    )

    $scriptBlock = [scriptblock]::Create("& `"$Executable`" $ArgumentList 2>&1; if (`$LASTEXITCODE -ne 0) { throw 'ExitCode: ' + `$LASTEXITCODE }")

    $jobResult = Invoke-JobWithTimeout -ScriptBlock $scriptBlock -Activity $Activity -IdleTimeoutEnabled $IdleTimeoutEnabled

    $outputString = $jobResult.Output -join "`n"

    $result = [PSCustomObject]@{
        Success = $jobResult.Success
        Output = $outputString
    }

    if ($jobResult.Error -match "ExitCode: (\d+)") {
        $result.Success = $false
        Write-Styled -Type Error -Message "El comando '$Executable' terminó con código de error: $($matches[1])."
    }

    # Incluso si el código de salida es 0, buscar cadenas de error en la salida
    if ($result.Success) {
        foreach ($failureString in $FailureStrings) {
            if ($result.Output -match $failureString) {
                $result.Success = $false
                Write-Styled -Type Warn -Message "Se encontró una cadena de error en la salida: '$failureString'"
                break # Un fallo es suficiente
            }
        }
    }

    return $result
}