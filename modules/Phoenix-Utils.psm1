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

# DEFINICIONES DE CLASES GLOBALES
class PackageStatus {
    [string]$DisplayName
    [psobject]$Package
    [string]$Status
    [string]$VersionInfo
    [bool]$IsUpgradable
}

# FUNCIONES DE UI
function Show-PhoenixHeader {
    param(
        [string]$TitleText,
        [switch]$NoClear
    )
    if (-not $NoClear) { Clear-Host }

    $titleColor = if ($Global:Theme.Title) { $Global:Theme.Title } else { "Cyan" }
    $borderColor = if ($Global:Theme.Subtle) { $Global:Theme.Subtle } else { "DarkGray" }

    # Un estilo más limpio y accesible que el anterior arte ASCII.
    $separator = "─" * ($TitleText.Length + 4) # Un poco más largo que el título para un efecto visual agradable.

    Write-Host
    Write-Host "  $($TitleText.ToUpper())" -ForegroundColor $titleColor
    Write-Host "  $separator" -ForegroundColor $borderColor
    Write-Host
}

function Write-PhoenixStyledOutput {
    param([string]$Message, [string]$Type = "Info", [switch]$NoNewline)
    $prefixMap = @{ Step="  -> "; SubStep="     - "; Success=" [ÉXITO] "; Warn=" [ADVERTENCIA] "; Skip=" [OMITIDO] "; Error=" [ERROR] "; Log="       | " }
    $prefix = $prefixMap[$Type]

    # Asignar un color por defecto si el tipo no está en el tema.
    # Esto es útil para tipos nuevos como 'Skip' sin necesidad de que todos los temas lo definan.
    $color = $Global:Theme[$Type]
    if (-not $color) { $color = "White" } # Fallback to white if color not in theme

    if ($NoNewline) { Write-Host "$prefix$Message" -ForegroundColor $color -NoNewline }
    else { Write-Host "$prefix$Message" -ForegroundColor $color }
}

function Show-PhoenixStandardMenu {
    param(
        [string]$Title,
        [array]$MenuItems,
        $ActionOptions,
        [string]$PromptMessage = "Seleccione una opción"
    )
    Show-PhoenixHeader -Title $Title

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
    $numericChoices = 1..$MenuItems.Count | ForEach-Object { "$_" }
    $validChoices = @($numericChoices)
    foreach ($key in $ActionOptions.Keys) {
        Write-PhoenixStyledOutput -Type Consent -Message "-> [$key] $($ActionOptions[$key])"
        $validChoices += $key
    }

    return Request-MenuSelection -ValidChoices $validChoices -PromptMessage $PromptMessage -AllowMultipleSelections
}

function Request-Continuation {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message
    )
    Write-Host
    Write-PhoenixStyledOutput -Type Consent -Message "$Message" -NoNewline
    Read-Host | Out-Null
}

function Confirm-SystemRestart {
    Write-PhoenixStyledOutput -Type Warn -Message "Se requiere un reinicio para aplicar completamente los cambios."
    if ((Request-MenuSelection -ValidChoices @('S','N') -PromptMessage "Desea reiniciar el equipo ahora?" -IsYesNoPrompt) -eq 'S') {
        Write-PhoenixStyledOutput -Type Info -Message "Reiniciando el equipo en 5 segundos..."
        Start-Sleep -Seconds 5
        Restart-Computer -Force
    } else {
        Write-PhoenixStyledOutput -Type Warn -Message "ACCIÓN MANUAL REQUERIDA: Por favor, reinicie el equipo lo antes posible."
    }
}

function Request-MenuSelection {
    param(
        [string]$PromptMessage = "Seleccione una opción",
        [string[]]$ValidChoices,
        [switch]$AllowMultipleSelections,
        [switch]$IsYesNoPrompt
    )

    try {
        while ($true) {
            $fullPrompt = "  -> $PromptMessage"
            if ($IsYesNoPrompt) {
                $fullPrompt += " (S/N)"
            }
            elseif ($AllowMultipleSelections) {
                $fullPrompt += " (se permiten múltiples, ej: 1,3,5-8)"
            }
            $fullPrompt += ": "

            $input = (Read-Host -Prompt $fullPrompt).Trim().ToUpper()
            if ([string]::IsNullOrWhiteSpace($input)) { continue }

            # Normalización de entrada para S/N
            if ($IsYesNoPrompt) {
                if ('SI', 'S', 'Y', 'YES' -contains $input) { $input = 'S' }
                elseif ('NO', 'N' -contains $input) { $input = 'N' }
            }

            $expandedChoices = [System.Collections.Generic.List[string]]::new()
            $validInput = $true

            if ($AllowMultipleSelections) {
                 # Dividir la entrada por comas y procesar cada parte.
                $parts = $input -split ','
                foreach ($part in $parts) {
                    $part = $part.Trim()
                    if ($part -match '(\w+)-(\w+)') { # Es un rango como '5-8'
                        $start = $matches[1]; $end = $matches[2]
                        # Validar que los rangos son numéricos y en el orden correcto.
                        if ($start -match '^\d+$' -and $end -match '^\d+$' -and [int]$start -le [int]$end) {
                            ([int]$start..[int]$end) | ForEach-Object { $expandedChoices.Add("$_") }
                        } else {
                            $validInput = $false; break
                        }
                    } else { # Es un solo valor
                        $expandedChoices.Add($part)
                    }
                }
            } else {
                # Si no se permiten múltiples selecciones, tomar solo la primera "palabra"
                $expandedChoices.Add(($input -split ' ')[0])
            }


            if (-not $validInput) {
                Write-PhoenixStyledOutput -Type Error -Message "Rango no válido detectado. Use un formato como '5-8'."; Start-Sleep -s 1; Write-Host; continue
            }

            # Validar cada elección expandida contra las opciones válidas.
            $finalChoices = [System.Collections.Generic.List[string]]::new()
            $invalidChoices = [System.Collections.Generic.List[string]]::new()
            foreach ($choice in $expandedChoices) {
                if ($ValidChoices -contains $choice) {
                    $finalChoices.Add($choice)
                } else {
                    $invalidChoices.Add($choice)
                }
            }

            if ($invalidChoices.Count -gt 0) {
                Write-PhoenixStyledOutput -Type Error -Message "Opciones no válidas: $($invalidChoices -join ', ')"; Start-Sleep -s 1; Write-Host
            } else {
                if ($AllowMultipleSelections) {
                    return $finalChoices.ToArray()
                }
                return $finalChoices[0]
            }
        }
    } catch [System.Management.Automation.PipelineStoppedException] {
        throw
    }
}

function Start-JobWithTimeout {
    param(
        [scriptblock]$ScriptBlock,
        [string]$Activity = "Ejecutando operación en segundo plano...",
        [int]$TimeoutSeconds = 3600,
        [boolean]$IdleTimeoutEnabled = $true,
        [int]$IdleTimeoutSeconds = 300,
        [string]$ProgressRegex
    )

    $job = Start-Job -ScriptBlock $ScriptBlock
    $overallTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $overallTimeout = New-TimeSpan -Seconds $TimeoutSeconds
    $idleTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $idleTimeout = New-TimeSpan -Seconds $IdleTimeoutSeconds

    $outputBuffer = New-Object System.Text.StringBuilder
    $lastProgressPercent = -1

    Write-PhoenixStyledOutput -Type Info -Message "Iniciando tarea: $Activity"

    while ($job.State -eq 'Running') {
        # --- Timeouts ---
        if ($overallTimer.Elapsed -gt $overallTimeout) { Stop-Job $job; throw "La operación '$Activity' excedió el tiempo límite total de $TimeoutSeconds segundos." }
        if ($IdleTimeoutEnabled -and $idleTimer.Elapsed -gt $idleTimeout) { Stop-Job $job; throw "La operación '$Activity' no mostró actividad por más de $IdleTimeoutSeconds segundos y fue terminada." }

        # --- Recibir y procesar nueva salida ---
        $newData = $job.ChildJobs[0].Output.ReadAll()
        if ($newData) {
            $idleTimer.Restart() # Reiniciar temporizador de inactividad
            [void]$outputBuffer.Append($newData -join [System.Environment]::NewLine)

            # --- Lógica de parseo de progreso (genérica) ---
            if ($ProgressRegex) {
                # Buscar en todas las líneas nuevas, de abajo hacia arriba, la última que coincida.
                $lastLineWithProgress = $newData | Where-Object { $_ -match $ProgressRegex } | Select-Object -Last 1
                if ($lastLineWithProgress -and ($lastLineWithProgress -match $ProgressRegex)) {
                    # El primer grupo de captura debe ser el número del porcentaje.
                    $percent = [int]$matches[1]
                    if ($percent -ne -1 -and $percent -ne $lastProgressPercent) {
                        $lastProgressPercent = $percent
                        $statusMessage = "Progreso: ${percent}% | Tiempo: $($overallTimer.Elapsed.ToString('hh\:mm\:ss'))"
                        Write-Progress -Activity $Activity -Status $statusMessage -PercentComplete $percent
                    }
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

function Invoke-RegistryActionWithPrivileges {
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
                Write-PhoenixStyledOutput -Type Error -Message "FALLO CRÍTICO al restaurar permisos en '$KeyPath'. Se requiere intervención manual."
            }
        }
    }
}


function Invoke-NativeCommandWithOutputCapture {
    param(
        [string]$Executable,
        [string]$ArgumentList,
        [string[]]$FailureStrings,
        [string]$Activity,
        [boolean]$IdleTimeoutEnabled = $true,
        [string]$ProgressRegex
    )

    # Set console encoding to UTF-8 within the job's scriptblock to ensure correct character decoding from native commands.
    $scriptBlock = [scriptblock]::Create("[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; & `"$Executable`" $ArgumentList 2>&1; if (`$LASTEXITCODE -ne 0) { throw 'ExitCode: ' + `$LASTEXITCODE }")

    $jobResult = Start-JobWithTimeout -ScriptBlock $scriptBlock -Activity $Activity -IdleTimeoutEnabled $IdleTimeoutEnabled -ProgressRegex $ProgressRegex

    $outputString = $jobResult.Output -join "`n"


    $result = [PSCustomObject]@{
        Success = $jobResult.Success
        Output = $outputString
    }

    if ($jobResult.Error -match "ExitCode: (\d+)") {
        $result.Success = $false
        Write-PhoenixStyledOutput -Type Error -Message "El comando '$Executable' terminó con código de error: $($matches[1])."
    }

    # Incluso si el código de salida es 0, buscar cadenas de error en la salida
    if ($result.Success) {
        foreach ($failureString in $FailureStrings) {
            if ($result.Output -match $failureString) {
                $result.Success = $false
                Write-PhoenixStyledOutput -Type Warn -Message "Se encontró una cadena de error en la salida: '$failureString'"
                break # Un fallo es suficiente
            }
        }
    }

    return $result
}

function Test-JsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
        [string]$Path
    )

    process {
        try {
            Get-Content -Path $Path -Raw | ConvertFrom-Json -ErrorAction Stop | Out-Null
            return $true
        } catch {
            # This is not a fatal error, the calling function will handle the false return.
            # We log it here for better debuggability.
            Write-PhoenixStyledOutput -Type Log -Message "El fichero JSON en '$Path' no es válido. Error: $($_.Exception.Message)"
            return $false
        }
    }
}

function Test-SoftwareCatalogIntegrity {
    param(
        [psobject]$CatalogData,
        [string]$CatalogFileName
    )
    if (-not $CatalogData.PSObject.Properties.Match('items')) {
        Write-PhoenixStyledOutput -Type Error -Message "El fichero de catálogo '$($CatalogFileName)' no contiene la clave raíz 'items'."
        return $false
    }
    if ($CatalogData.items -isnot [array]) {
        Write-PhoenixStyledOutput -Type Error -Message "La clave 'items' en '$($CatalogFileName)' debe ser un array."
        return $false
    }

    $isValid = $true
    for ($i = 0; $i -lt $CatalogData.items.Count; $i++) {
        $item = $CatalogData.items[$i]
        if (-not $item.PSObject.Properties.Match('installId') -or -not $item.installId -or $item.installId -isnot [string]) {
            Write-PhoenixStyledOutput -Type Error -Message "El ítem #$($i+1) en '$($CatalogFileName)' no tiene una propiedad 'installId' válida (string, no vacía)."
            $isValid = $false
        }
    }
    return $isValid
}

function Start-PostInstallConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Package
    )

    $friendlyName = if ($Package.name) { $Package.name } else { $Package.installId }

    if ([string]::IsNullOrWhiteSpace($Package.installId)) {
        Write-PhoenixStyledOutput -Type Error -Message "El paquete '$friendlyName' tiene un 'installId' inválido y no se puede procesar la configuración."
        return
    }

    $projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    $sourceConfigDir = Join-Path (Join-Path $projectRoot "assets/configs") $Package.installId

    if (-not (Test-Path $sourceConfigDir)) {
        Write-PhoenixStyledOutput -Type Warn -Message "No se encontró un directorio de configuración de origen para '$friendlyName' en '$sourceConfigDir'."
        return
    }

    if (-not ($Package.PSObject.Properties.Match('configPaths') -and $Package.configPaths)) {
        Write-PhoenixStyledOutput -Type Warn -Message "El paquete '$friendlyName' está marcado para post-configuración pero no define 'configPaths' en el catálogo."
        return
    }

    Write-PhoenixStyledOutput -Type Consent -Message "El paquete '$friendlyName' tiene una configuración de productividad/accesibilidad disponible."
    if ('N' -eq (Request-MenuSelection -ValidChoices @('S', 'N') -PromptMessage '¿Desea aplicar esta configuración ahora?' -IsYesNoPrompt)) {
        Write-PhoenixStyledOutput -Type Info -Message "Se omitió la aplicación de la configuración para '$friendlyName'."
        return
    }

    $destinationPath = $null
    foreach ($path in $Package.configPaths) {
        $expandedPath = $ExecutionContext.InvokeCommand.ExpandString($path)
        if (Test-Path $expandedPath) {
            $destinationPath = $expandedPath
            break
        }
    }

    if (-not $destinationPath) {
        Write-PhoenixStyledOutput -Type Error -Message "No se pudo encontrar una ruta de instalación válida para '$friendlyName' en ninguna de las siguientes ubicaciones:"
        $Package.configPaths | ForEach-Object { Write-PhoenixStyledOutput -Type Log -Message "- $_" }
        Request-Continuation
        return
    }

    Write-PhoenixStyledOutput -Type Info -Message "Aplicando configuración para '$friendlyName' en '$destinationPath'..."

    try {
        if (-not (Test-Path $destinationPath)) {
            Write-PhoenixStyledOutput -Type SubStep -Message "El directorio de destino no existe, creándolo..."
            New-Item -Path $destinationPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }

        $sourceFiles = Get-ChildItem -Path $sourceConfigDir
        if ($sourceFiles.Count -eq 0) {
            Write-PhoenixStyledOutput -Type Warn -Message "El directorio de configuración de origen está vacío."
            return
        }

        foreach ($file in $sourceFiles) {
            $destinationFile = Join-Path $destinationPath $file.Name
            Write-PhoenixStyledOutput -Type SubStep -Message "Copiando '$($file.Name)'..."
            Copy-Item -Path $file.FullName -Destination $destinationFile -Force -ErrorAction Stop
        }

        Write-PhoenixStyledOutput -Type Success -Message "La configuración para '$friendlyName' se ha aplicado correctamente."
        Request-Continuation
    } catch {
        Write-PhoenixStyledOutput -Type Error -Message "Ocurrió un error al aplicar la configuración para '$friendlyName'."
        Write-PhoenixStyledOutput -Type Log -Message "Ruta de origen: $sourceConfigDir"
        Write-PhoenixStyledOutput -Type Log -Message "Ruta de destino: $destinationPath"
        Write-PhoenixStyledOutput -Type Log -Message "Error: $($_.Exception.Message)"
        Request-Continuation
    }
}

#region Environment Functions
function Set-FileEncodingToUtf8 {
    param(
        [string]$BasePath,
        [string[]]$Extensions
    )
    Write-PhoenixStyledOutput -Type Step -Message "Verificando la codificación de los ficheros del script..."

    $files = Get-ChildItem -Path $BasePath -Recurse -Include $Extensions -File
    $utf8Bom = [byte[]](0xEF, 0xBB, 0xBF)
    $convertedCount = 0

    foreach ($file in $files) {
        try {
            $fileBytes = Get-Content -Path $file.FullName -Encoding Byte -TotalCount 3

            $hasBom = $false
            if ($fileBytes.Length -ge 3) {
                if ($fileBytes[0] -eq $utf8Bom[0] -and $fileBytes[1] -eq $utf8Bom[1] -and $fileBytes[2] -eq $utf8Bom[2]) {
                    $hasBom = $true
                }
            }

            if (-not $hasBom) {
                Write-PhoenixStyledOutput -Type SubStep -Message "Convirtiendo a UTF-8 con BOM: $($file.Name)"
                $content = Get-Content -Path $file.FullName
                Set-Content -Path $file.FullName -Value $content -Encoding UTF8 -Force
                $convertedCount++
            }
        } catch {
            Write-PhoenixStyledOutput -Type Warn -Message "No se pudo procesar el fichero '$($file.Name)'. Error: $($_.Exception.Message)"
        }
    }

    if ($convertedCount -gt 0) {
        Write-PhoenixStyledOutput -Type Success -Message "Conversión de codificación completada para $convertedCount fichero(s)."
    } else {
        Write-PhoenixStyledOutput -Type Success -Message "Todos los ficheros ya tienen la codificación correcta (UTF-8 con BOM)."
    }
}
#endregion

#region Package Management Helpers
function Get-PackageStatusFromCatalog {
    [CmdletBinding()]
    param(
        [string]$ManagerName,
        [array]$CatalogPackages,
        [scriptblock]$StatusCheckBlock
    )
    $packageStatusList = [System.Collections.Generic.List[PackageStatus]]::new()
    for ($i = 0; $i -lt $CatalogPackages.Count; $i++) {
        $pkg = $CatalogPackages[$i]
        $displayName = if ($pkg.name) { $pkg.name } else { $pkg.installId }
        Write-Progress -Activity "Procesando estado de paquetes de $ManagerName" -Status "Verificando: ${displayName}" -PercentComplete (($i / $CatalogPackages.Count) * 100)

        $statusInfo = & $StatusCheckBlock -Package $pkg

        $packageStatusList.Add([PackageStatus]@{
            DisplayName  = $displayName
            Package      = $pkg
            Status       = $statusInfo.Status
            VersionInfo  = $statusInfo.VersionInfo
            IsUpgradable = $statusInfo.IsUpgradable
        })
    }
    Write-Progress -Activity "Procesando estado de paquetes de $ManagerName" -Completed
    return $packageStatusList
}
#endregion

Export-ModuleMember -Function *
