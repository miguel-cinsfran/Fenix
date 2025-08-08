<#
.SYNOPSIS
    Módulo de Fase 5 para la limpieza y optimización del sistema.
.DESCRIPTION
    Contiene un menú de tareas de limpieza, algunas automáticas y otras interactivas,
    cargadas desde un catálogo JSON para mayor modularidad.
.NOTES
    Versión: 1.1
    Autor: miguel-cinsfran
    Revisión: Corregida la codificación de caracteres y mejorada la legibilidad.
#>

#region Cleanup Task Helpers
function _Invoke-CleanupTask-SimpleCommand {
    param($Task)
    Write-PhoenixStyledOutput -Type SubStep -Message "Ejecutando: $($Task.description)..."
    $result = Start-JobWithTimeout -ScriptBlock ([scriptblock]::Create($Task.details.command)) -Activity $Task.description -TimeoutSeconds 1800
    if ($result.Success) {
        Write-PhoenixStyledOutput -Type Success -Message "Tarea '$($Task.description)' completada."
        if ($Task.rebootRequired) { $global:RebootIsPending = $true }
    } else {
        Write-PhoenixStyledOutput -Type Error -Message "La tarea '$($Task.description)' falló: $($result.Error)"
    }
}

function _Invoke-CleanupTask-DiskCleanup {
    param($Task)
    Write-PhoenixStyledOutput -Type SubStep -Message "Analizando discos..."
    $drives = Get-CimInstance -ClassName Win32_Volume | Where-Object { $_.DriveType -eq 3 -and $_.DriveLetter }
    foreach ($drive in $drives) {
        try {
            Optimize-Volume -DriveLetter $drive.DriveLetter.Trim(":") -Verbose
        } catch {
            Write-PhoenixStyledOutput -Type Error -Message "No se pudo optimizar la unidad $($drive.DriveLetter): $($_.Exception.Message)"
        }
    }
    Write-PhoenixStyledOutput -Type Success -Message "Optimización de discos completada."
}

function _Invoke-CleanupTask-FindLargeFiles {
    param($Task)
    Write-PhoenixStyledOutput -Type SubStep -Message "Buscando archivos grandes... Esto puede tardar MUCHO tiempo."
    $files = Get-ChildItem -Path $Task.details.drive -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt ($Task.details.minSizeMB * 1MB) } | Sort-Object -Property Length -Descending | Select-Object -First $Task.details.count

    if ($files.Count -eq 0) { Write-PhoenixStyledOutput -Type Warn -Message "No se encontraron archivos que cumplan el criterio."; return }

    for ($i = 0; $i -lt $files.Count; $i++) {
        Write-Host ("[{0,2}] {1,-10} {2}" -f ($i + 1), ("{0:N2} GB" -f ($files[$i].Length / 1GB)), $files[$i].FullName)
    }
    Write-PhoenixStyledOutput -Type Consent -Message "`n¿Desea eliminar alguno de estos archivos? (Escriba los números separados por comas, o 0 para no borrar nada)"
    $choice = Read-Host
    if ($choice -eq '0') { return }

    $indicesToDelete = $choice -split ',' | ForEach-Object { [int]$_ - 1 }
    foreach ($index in $indicesToDelete) {
        if ($index -ge 0 -and $index -lt $files.Count) {
            Write-PhoenixStyledOutput -Type Info -Message "Eliminando $($files[$index].FullName)..."
            Remove-Item -Path $files[$index].FullName -Force
        }
    }
}

function _Invoke-CleanupTask-AnalyzeProcesses {
    param($Task)
    Write-PhoenixStyledOutput -Type Info -Message "Analizando procesos del sistema..."
    $processList = Get-Process -ErrorAction SilentlyContinue | Select-Object Name, Id, @{Name="Memory"; Expression={$_.WorkingSet}}, @{Name="CPUTime"; Expression={$_.TotalProcessorTime.TotalSeconds}}

    $cpuFormat = @{Name="CPU (s)"; Expression={$_.CPUTime.ToString('F2')}}
    $memFormat = @{Name="Memoria (MB)"; Expression={($_.Memory / 1MB).ToString('F2')}}

    # Capturar la salida de la tabla para darle un estilo consistente.
    $cpuTable = $processList | Sort-Object -Property CPUTime -Descending | Select-Object -First $Task.details.count | Format-Table Name, Id, $cpuFormat, $memFormat -AutoSize | Out-String
    $memTable = $processList | Sort-Object -Property Memory -Descending | Select-Object -First $Task.details.count | Format-Table Name, Id, $cpuFormat, $memFormat -AutoSize | Out-String

    Show-PhoenixHeader -Title "Top $($Task.details.count) procesos por consumo de CPU" -NoClear
    Write-Host $cpuTable -ForegroundColor $Global:PhoenixContext.Theme.Info

    Show-PhoenixHeader -Title "Top $($Task.details.count) procesos por consumo de Memoria (MB)" -NoClear
    Write-Host $memTable -ForegroundColor $Global:PhoenixContext.Theme.Info
}

function _Invoke-CleanupTask-SetDNS {
    param($Task)
    Write-PhoenixStyledOutput -Type Info -Message "Los servidores DNS públicos pueden ofrecer mayor velocidad y privacidad."
    if ((Request-MenuSelection -ValidChoices @('S','N') -PromptMessage "¿Desea cambiar sus servidores DNS a $($Task.details.name) ($($Task.details.servers -join ', '))?" -IsYesNoPrompt) -ne 'S') {
        Write-PhoenixStyledOutput -Type Skip -Message "Operación cancelada por el usuario."
        return
    }

    try {
        Write-PhoenixStyledOutput -Type SubStep -Message "Cambiando DNS a: $($Task.details.name)..."
        $adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
        if ($null -eq $adapters) { throw "No se encontraron adaptadores de red activos." }
        $adapters | Set-DnsClientServerAddress -ServerAddresses ($Task.details.servers) -ErrorAction Stop
        Write-PhoenixStyledOutput -Type Success -Message "DNS cambiado correctamente."
    } catch {
        Write-PhoenixStyledOutput -Type Error -Message "No se pudo cambiar el DNS: $($_.Exception.Message)"
    }
}

function _Invoke-CleanupTask-RecycleBinCleanup {
    param($Task)
    Write-PhoenixStyledOutput -Type SubStep -Message $Task.description
    $shell = New-Object -ComObject Shell.Application
    # El namespace 0xA representa la Papelera de Reciclaje.
    $recycleBin = $shell.NameSpace(0xA)
    $items = $recycleBin.Items()
    $itemCount = $items.Count

    # Salir temprano si no hay nada que hacer.
    if ($itemCount -eq 0) {
        Write-PhoenixStyledOutput -Type Success -Message "La Papelera de Reciclaje ya está vacía."
    } else {
        # Calcular el tamaño total. La propiedad 'Size' está en bytes.
        $totalSize = 0
        foreach ($item in $items) { $totalSize += $item.Size }

        # Formatear el tamaño a una unidad legible por humanos.
        $sizeFormatted = ""
        if ($totalSize -gt 1GB) { $sizeFormatted = "{0:N2} GB" -f ($totalSize / 1GB) }
        elseif ($totalSize -gt 1MB) { $sizeFormatted = "{0:N2} MB" -f ($totalSize / 1MB) }
        else { $sizeFormatted = "{0:N0} KB" -f ($totalSize / 1KB) }

        $prompt = "La Papelera contiene $itemCount elemento(s) (aprox. $sizeFormatted). ¿Confirma que desea vaciarla permanentemente?"
        if ((Request-MenuSelection -ValidChoices @('S','N') -PromptMessage $prompt -IsYesNoPrompt) -eq 'S') {
            # Usar Clear-RecycleBin, que es el cmdlet estándar.
            # -ErrorAction SilentlyContinue evita que errores en ficheros individuales (ej. bloqueados) detengan el proceso
            # o muestren un error feo si la mayoría de ficheros se borran bien.
            Clear-RecycleBin -Force -ErrorAction SilentlyContinue

            # Verificar el resultado volviendo a contar los elementos.
            if ($recycleBin.Items().Count -eq 0) {
                Write-PhoenixStyledOutput -Type Success -Message "La Papelera de Reciclaje ha sido vaciada."
            } else {
                Write-PhoenixStyledOutput -Type Error -Message "No se pudo vaciar la Papelera por completo. Algunos elementos pueden permanecer."
            }
        } else {
            Write-PhoenixStyledOutput -Type Skip -Message "Operación cancelada por el usuario."
        }
    }

    # Liberar los objetos COM para evitar fugas de memoria.
    try {
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($recycleBin) | Out-Null
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
    } catch {
        # Ignorar errores durante la liberación, no son críticos para el usuario.
    }
}

function _Invoke-CleanupTask-WindowsUpdateCleanup {
    param($Task)
    Write-PhoenixStyledOutput -Type SubStep -Message $Task.description
    Write-PhoenixStyledOutput -Type Warn -Message "Esta operación puede tardar mucho tiempo."
    if ((Request-MenuSelection -ValidChoices @('S','N') -PromptMessage "¿Desea proceder con la limpieza profunda?" -IsYesNoPrompt) -eq 'S') {
        $result = Invoke-NativeCommandWithOutputCapture -Executable "Dism.exe" -ArgumentList "/Online /English /Cleanup-Image /StartComponentCleanup /ResetBase" -FailureStrings "Error:" -Activity "Limpiando archivos de Windows Update"
        if ($result.Success) {
            Write-PhoenixStyledOutput -Type Success -Message "Tarea '$($Task.description)' completada."
            if ($Task.rebootRequired) { $global:RebootIsPending = $true }
        } else {
            Write-PhoenixStyledOutput -Type Error -Message "La tarea '$($Task.description)' falló."
        }
    }
}
#endregion

function Invoke-CleanupPhase {
    param([string]$CatalogPath)

    try {
        if (-not (Test-Path $CatalogPath)) {
            throw "No se encontró el fichero de catálogo en '$CatalogPath'."
        }
        $catalogContent = Get-Content -Raw -Path $CatalogPath -Encoding UTF8
        $catalogJson = $catalogContent | ConvertFrom-Json

        if (-not (Test-JsonFile -Path $CatalogPath)) {
            throw "El fichero de catálogo '$((Split-Path $CatalogPath -Leaf))' contiene JSON inválido."
        }
        $tasks = $catalogJson.items
    } catch {
        Write-PhoenixStyledOutput -Type Error -Message "Fallo CRÍTICO al leer o procesar el catálogo de limpieza: $($_.Exception.Message)"
        Request-Continuation -Message "Presione Enter para volver al menú principal..."
        return
    }

    $exitMenu = $false
    while (-not $exitMenu) {
        $menuItems = $tasks | ForEach-Object { [PSCustomObject]@{ Description = $_.description } }
        $actionOptions = [ordered]@{ '0' = 'Volver al Menú Principal.' }
        $choices = Show-PhoenixStandardMenu -Title "FASE 5: Limpieza y Optimización del Sistema" -MenuItems $menuItems -ActionOptions $actionOptions

        if ($choices -contains '0') { $exitMenu = $true; continue }

        $actionTaken = $false
        $numericActions = $choices | ForEach-Object { [int]$_ } | Sort-Object

        foreach ($choice in $numericActions) {
            $selectedTask = $tasks[$choice - 1]
            $functionName = "_Invoke-CleanupTask-$($selectedTask.type)"

            if (Get-Command $functionName -ErrorAction SilentlyContinue) {
                & $functionName -Task $selectedTask
                $actionTaken = $true
            } else {
                Write-PhoenixStyledOutput -Type Error -Message "Tipo de tarea desconocido: '$($selectedTask.type)'"
                $actionTaken = $true # Pausar incluso si hay error.
            }
        }

        if ($actionTaken) {
            # Pausar solo para tareas que no son instantáneas y muestran mucha información.
            $pauseTasks = @("FindLargeFiles", "AnalyzeProcesses")
            if ($selectedTask.type -in $pauseTasks) {
                Request-Continuation -Message "Presione Enter para volver al menú de limpieza..."
            }
        }
    }
}

# Exportar únicamente las funciones destinadas al consumo público para evitar la
# exposición de helpers internos y cumplir con las mejores prácticas de modularización.
Export-ModuleMember -Function Invoke-CleanupPhase
