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
    Write-Styled -Type SubStep -Message "Ejecutando: $($Task.description)..."
    $result = Invoke-JobWithTimeout -ScriptBlock ([scriptblock]::Create($Task.details.command)) -Activity $Task.description -TimeoutSeconds 1800
    if ($result.Success) {
        Write-Styled -Type Success -Message "Tarea '$($Task.description)' completada."
        if ($Task.rebootRequired) { $global:RebootIsPending = $true }
    } else {
        Write-Styled -Type Error -Message "La tarea '$($Task.description)' falló: $($result.Error)"
    }
}

function _Invoke-CleanupTask-DiskCleanup {
    param($Task)
    Write-Styled -Type SubStep -Message "Analizando discos..."
    $drives = Get-CimInstance -ClassName Win32_Volume | Where-Object { $_.DriveType -eq 3 -and $_.DriveLetter }
    foreach ($drive in $drives) {
        try {
            Optimize-Volume -DriveLetter $drive.DriveLetter.Trim(":") -Verbose
        } catch {
            Write-Styled -Type Error -Message "No se pudo optimizar la unidad $($drive.DriveLetter): $($_.Exception.Message)"
        }
    }
    Write-Styled -Type Success -Message "Optimización de discos completada."
}

function _Invoke-CleanupTask-FindLargeFiles {
    param($Task)
    Write-Styled -Type SubStep -Message "Buscando archivos grandes... Esto puede tardar MUCHO tiempo."
    $files = Get-ChildItem -Path $Task.details.drive -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt ($Task.details.minSizeMB * 1MB) } | Sort-Object -Property Length -Descending | Select-Object -First $Task.details.count

    if ($files.Count -eq 0) { Write-Styled -Type Warn -Message "No se encontraron archivos que cumplan el criterio."; return }

    for ($i = 0; $i -lt $files.Count; $i++) {
        Write-Host ("[{0,2}] {1,-10} {2}" -f ($i + 1), ("{0:N2} GB" -f ($files[$i].Length / 1GB)), $files[$i].FullName)
    }
    Write-Styled -Type Consent -Message "`n¿Desea eliminar alguno de estos archivos? (Escriba los números separados por comas, o 0 para no borrar nada)"
    $choice = Read-Host
    if ($choice -eq '0') { return }

    $indicesToDelete = $choice -split ',' | ForEach-Object { [int]$_ - 1 }
    foreach ($index in $indicesToDelete) {
        if ($index -ge 0 -and $index -lt $files.Count) {
            Write-Styled -Type Info -Message "Eliminando $($files[$index].FullName)..."
            Remove-Item -Path $files[$index].FullName -Force
        }
    }
}

function _Invoke-CleanupTask-AnalyzeProcesses {
    param($Task)
    Write-Styled -Type Info -Message "Analizando procesos del sistema..."
    $processList = Get-Process -ErrorAction SilentlyContinue | Select-Object Name, Id, @{Name="Memory"; Expression={$_.WorkingSet}}, @{Name="CPUTime"; Expression={$_.TotalProcessorTime.TotalSeconds}}

    $cpuFormat = @{Name="CPU (s)"; Expression={$_.CPUTime.ToString('F2')}}
    $memFormat = @{Name="Memoria (MB)"; Expression={($_.Memory / 1MB).ToString('F2')}}

    Write-Styled -Type SubStep -Message "Top $($Task.details.count) procesos por consumo de CPU:"
    $processList | Sort-Object -Property CPUTime -Descending | Select-Object -First $Task.details.count | Format-Table Name, Id, $cpuFormat, $memFormat -AutoSize

    Write-Styled -Type SubStep -Message "Top $($Task.details.count) procesos por consumo de Memoria (MB):"
    $processList | Sort-Object -Property Memory -Descending | Select-Object -First $Task.details.count | Format-Table Name, Id, $cpuFormat, $memFormat -AutoSize
}

function _Invoke-CleanupTask-SetDNS {
    param($Task)
    Write-Styled -Type Info -Message "Los servidores DNS públicos pueden ofrecer mayor velocidad y privacidad."
    if ((Invoke-MenuPrompt -ValidChoices @('S','N') -PromptMessage "¿Desea cambiar sus servidores DNS a $($Task.details.name) ($($Task.details.servers -join ', '))?") -ne 'S') {
        Write-Styled -Type Warn -Message "Operación cancelada."
        return
    }

    try {
        Write-Styled -Type SubStep -Message "Cambiando DNS a: $($Task.details.name)..."
        $adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
        if ($null -eq $adapters) { throw "No se encontraron adaptadores de red activos." }
        $adapters | Set-DnsClientServerAddress -ServerAddresses ($Task.details.servers) -ErrorAction Stop
        Write-Styled -Type Success -Message "DNS cambiado correctamente."
    } catch {
        Write-Styled -Type Error -Message "No se pudo cambiar el DNS: $($_.Exception.Message)"
    }
}

function _Invoke-CleanupTask-RecycleBinCleanup {
    param($Task)
    Write-Styled -Type SubStep -Message $Task.description
    try {
        $shell = New-Object -ComObject Shell.Application
        $recycleBin = $shell.NameSpace(0xA)
        if ($recycleBin.Items().Count -eq 0) {
            Write-Styled -Type Success -Message "La Papelera de Reciclaje ya está vacía."
        } else {
            if ((Invoke-MenuPrompt -ValidChoices @('S','N') -PromptMessage "¿Confirma que desea vaciar la papelera permanentemente?") -eq 'S') {
                Clear-RecycleBin -Force -ErrorAction Stop
                Write-Styled -Type Success -Message "Papelera de Reciclaje vaciada."
            }
        }
    } catch {
        Write-Styled -Type Error -Message "No se pudo procesar la Papelera de Reciclaje: $($_.Exception.Message)"
    }
}

function _Invoke-CleanupTask-WindowsUpdateCleanup {
    param($Task)
    Write-Styled -Type SubStep -Message $Task.description
    Write-Styled -Type Warn -Message "Esta operación puede tardar mucho tiempo."
    if ((Invoke-MenuPrompt -ValidChoices @('S','N') -PromptMessage "¿Desea proceder con la limpieza profunda?") -eq 'S') {
        $result = Invoke-NativeCommand -Executable "Dism.exe" -ArgumentList "/Online /English /Cleanup-Image /StartComponentCleanup /ResetBase" -FailureStrings "Error:" -Activity "Limpiando archivos de Windows Update"
        if ($result.Success) {
            Write-Styled -Type Success -Message "Tarea '$($Task.description)' completada."
            if ($Task.rebootRequired) { $global:RebootIsPending = $true }
        } else {
            Write-Styled -Type Error -Message "La tarea '$($Task.description)' falló."
        }
    }
}
#endregion

function Invoke-Phase5_Cleanup {
    param([string]$CatalogPath)
    $cleanupCatalogFile = Join-Path $CatalogPath "system_cleanup.json"
    if (-not (Test-Path $cleanupCatalogFile)) {
        Write-Styled -Type Error -Message "No se encontró el catálogo de limpieza en '$cleanupCatalogFile'."; Pause-And-Return; return
    }

    try {
        $tasks = (Get-Content -Raw -Path $cleanupCatalogFile -Encoding UTF8 | ConvertFrom-Json).items
    } catch {
        Write-Styled -Type Error -Message "Fallo CRÍTICO al procesar '$cleanupCatalogFile'."; Pause-And-Return; return
    }

    $exitMenu = $false
    while (-not $exitMenu) {
        $menuItems = $tasks | ForEach-Object { [PSCustomObject]@{ Description = $_.description } }
        $actionOptions = [ordered]@{ '0' = 'Volver al Menú Principal.' }
        $choice = Invoke-StandardMenu -Title "FASE 5: Limpieza y Optimización del Sistema" -MenuItems $menuItems -ActionOptions $actionOptions

        if ($choice -eq '0') { $exitMenu = $true; continue }

        $actionTaken = $false
        $selectedTask = $tasks[[int]$choice - 1]
        $functionName = "_Invoke-CleanupTask-$($selectedTask.type)"

        if (Get-Command $functionName -ErrorAction SilentlyContinue) {
            & $functionName -Task $selectedTask
            $actionTaken = $true
        } else {
            Write-Styled -Type Error -Message "Tipo de tarea desconocido: '$($selectedTask.type)'"
            $actionTaken = $true # Pausar incluso si hay error.
        }

        if ($actionTaken) { Pause-And-Return }
    }
}
