<#
.SYNOPSIS
    Módulo de Fase 5 para la limpieza y optimización del sistema.
.DESCRIPTION
    Contiene un menú de tareas de limpieza, algunas automáticas y otras interactivas,
    cargadas desde un catálogo JSON para mayor modularidad.
.NOTES
    Versión: 1.0
    Autor: miguel-cinsfran
#>

function _Invoke-SimpleCommand {
    param($Task)
    Write-Styled -Type SubStep -Message "Ejecutando: $($Task.description)..."
    $result = Invoke-JobWithTimeout -ScriptBlock ([scriptblock]::Create($Task.details.command)) -Activity $Task.description -TimeoutSeconds 1800
    if ($result.Success) {
        Write-Styled -Type Success -Message "Tarea '$($Task.description)' completada."
    } else {
        Write-Styled -Type Error -Message "La tarea '$($Task.description)' falló: $($result.Error)"
    }
    Pause-And-Return
}

function _Invoke-DiskCleanup {
    Write-Styled -Type SubStep -Message "Analizando discos..."
    $drives = Get-CimInstance -ClassName Win32_Volume | Where-Object { $_.DriveType -eq 3 -and $_.DriveLetter }
    foreach ($drive in $drives) {
        try {
            $physicalDisk = Get-Partition -DriveLetter $drive.DriveLetter.Trim(":") | Get-PhysicalDisk
            $mediaType = $physicalDisk.MediaType
            $action = if ($mediaType -eq 'SSD') { "ReTrim" } else { "Defrag" }

            Write-Styled -Type Info -Message "Optimizando unidad $($drive.DriveLetter) ($mediaType) con la acción: $action..."
            # El cmdlet Optimize-Volume selecciona la acción correcta automáticamente.
            # Los parámetros -Defrag y -ReTrim son para forzar, pero es mejor dejar que decida.
            Optimize-Volume -DriveLetter $drive.DriveLetter.Trim(":") -Verbose
        } catch {
            Write-Styled -Type Error -Message "No se pudo optimizar la unidad $($drive.DriveLetter): $($_.Exception.Message)"
        }
    }
    Write-Styled -Type Success -Message "Optimización de discos completada."
    Pause-And-Return
}

function _Invoke-FindLargeFiles {
    param($Task)
    Write-Styled -Type SubStep -Message "Buscando archivos grandes... Esto puede tardar MUCHO tiempo."
    $files = Get-ChildItem -Path $Task.details.drive -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt ($Task.details.minSizeMB * 1MB) } | Sort-Object -Property Length -Descending | Select-Object -First $Task.details.count

    if ($files.Count -eq 0) { Write-Styled -Type Warn -Message "No se encontraron archivos que cumplan el criterio."; Pause-And-Return; return }

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
    Pause-And-Return
}

function _Invoke-AnalyzeProcesses {
    param($Task)
    Write-Styled -Type Info -Message "Analizando procesos del sistema..."

    # Excluir el proceso 'Idle' y manejar errores de acceso en otros procesos del sistema.
    $processes = Get-Process | Where-Object { $_.ProcessName -ne 'Idle' }

    Write-Styled -Type SubStep -Message "Top $($Task.details.count) procesos por consumo de CPU:"
    $cpuTop = $processes | Select-Object *, @{Name="SafeTotalProcessorTime"; Expression={
        try { return $_.TotalProcessorTime.TotalSeconds } catch { return 0 }
    }} | Sort-Object -Property SafeTotalProcessorTime -Descending | Select-Object -First $Task.details.count

    $cpuTop | Format-Table -Property Name, Id, @{Name="CPU (s)"; Expression={$_.SafeTotalProcessorTime.ToString('F2')}}, @{Name="Memoria (MB)"; Expression={($_.WorkingSet / 1MB).ToString('F2')}} -AutoSize

    Write-Styled -Type SubStep -Message "Top $($Task.details.count) procesos por consumo de Memoria (MB):"
    $memTop = $processes | Sort-Object -Property WorkingSet -Descending | Select-Object -First $Task.details.count
    $memTop | Format-Table -Property Name, Id, @{Name="CPU (s)"; Expression={(try {$_.TotalProcessorTime.TotalSeconds.ToString('F2')} catch {'N/A'})}}, @{Name="Memoria (MB)"; Expression={($_.WorkingSet / 1MB).ToString('F2')}} -AutoSize

    Pause-And-Return
}

function _Invoke-SetDNS {
    param($Task)
    Write-Styled -Type Info -Message "Los servidores DNS públicos como Cloudflare o Google pueden ofrecer mayor velocidad y privacidad que los de su proveedor de internet."
    Write-Styled -Type Consent -Message "¿Desea cambiar sus servidores DNS a $($Task.details.name) ($($Task.details.servers -join ', '))? (S/N)"
    if ((Read-Host).Trim().ToUpper() -ne 'S') { Write-Styled -Type Warn -Message "Operación cancelada."; Pause-And-Return; return }

    Write-Styled -Type SubStep -Message "Cambiando DNS a: $($Task.details.name)..."
    Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Set-DnsClientServerAddress -ServerAddresses ($Task.details.servers)
    Write-Styled -Type Success -Message "DNS cambiado correctamente."
    Pause-And-Return
}

function _Invoke-RecycleBinCleanup {
    param($Task)
    Write-Styled -Type SubStep -Message $Task.description
    $shell = New-Object -ComObject Shell.Application
    $recycleBin = $shell.NameSpace(0xA)
    $itemCount = $recycleBin.Items().Count

    if ($itemCount -eq 0) {
        Write-Styled -Type Success -Message "La Papelera de Reciclaje ya está vacía."
        Pause-And-Return
        return
    }

    # Calcular tamaño total. Esto puede ser lento si hay muchos archivos.
    $totalSize = 0
    foreach ($item in $recycleBin.Items()) {
        $totalSize += $item.Size
    }

    $sizeInMB = [math]::Round($totalSize / 1MB, 2)
    Write-Styled -Type Info -Message "Se encontraron $itemCount objeto(s) en la papelera, con un tamaño total de $sizeInMB MB."
    Write-Styled -Type Consent -Message "¿Confirma que desea vaciar la papelera permanentemente?"
    if ((Read-Host "(S/N)").Trim().ToUpper() -eq 'S') {
        Write-Styled -Message "Vaciando papelera..." -NoNewline
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        Write-Host " [ÉXITO]" -F $Global:Theme.Success
        Write-Styled -Type Success -Message "Se han liberado $sizeInMB MB de espacio."
    } else {
        Write-Styled -Type Warn -Message "Operación cancelada."
    }
    Pause-And-Return
}

function _Invoke-WindowsUpdateCleanup {
    param($Task)
    Write-Styled -Type SubStep -Message $Task.description
    Write-Styled -Type Info -Message "Esta operación eliminará archivos de instalación de Windows Update que ya no son necesarios."
    Write-Styled -Type Warn -Message "Puede liberar una cantidad significativa de espacio, pero puede tardar MUCHO tiempo en completarse."
    Write-Styled -Type Consent -Message "¿Desea proceder con la limpieza?"
    if ((Read-Host "(S/N)").Trim().ToUpper() -eq 'S') {
        $command = "Dism.exe /Online /English /Cleanup-Image /StartComponentCleanup /ResetBase"
        $result = Invoke-JobWithTimeout -ScriptBlock ([scriptblock]::Create($command)) -Activity "Limpiando archivos de Windows Update" -TimeoutSeconds 3600
        if ($result.Success) {
            Write-Styled -Type Success -Message "Tarea '$($Task.description)' completada."
        } else {
            Write-Styled -Type Error -Message "La tarea '$($Task.description)' falló: $($result.Error)"
        }
    } else {
        Write-Styled -Type Warn -Message "Operación cancelada."
    }
    Pause-And-Return
}

function Invoke-Phase5_Cleanup {
    param([PSCustomObject]$state, [string]$CatalogPath)
    if ($state.FatalErrorOccurred) { return $state }

    $cleanupCatalogFile = Join-Path $CatalogPath "system_cleanup.json"
    if (-not (Test-Path $cleanupCatalogFile)) {
        Write-Styled -Type Error -Message "No se encontró el catálogo de limpieza en '$cleanupCatalogFile'."
        $state.FatalErrorOccurred = $true
        return $state
    }

    try {
        $tasks = (Get-Content -Raw -Path $cleanupCatalogFile -Encoding UTF8 | ConvertFrom-Json).items
    } catch {
        Write-Styled -Type Error -Message "Fallo CRÍTICO al procesar '$cleanupCatalogFile'."
        $state.FatalErrorOccurred = $true
        return $state
    }

    $exitMenu = $false
    while (-not $exitMenu) {
        Show-Header -Title "FASE 5: Limpieza y Optimización del Sistema"
        for ($i = 0; $i -lt $tasks.Count; $i++) {
            Write-Styled -Type Step -Message "[$($i+1)] $($tasks[$i].description)"
        }
        Write-Styled -Type Step -Message "[0] Volver al Menú Principal"
        Write-Host

        $numericChoices = 1..$tasks.Count
        $validChoices = @($numericChoices) + @('0')
        $choice = Invoke-MenuPrompt -ValidChoices $validChoices -PromptMessage "Seleccione una tarea"

        if ($choice -eq '0') { $exitMenu = $true; continue }

        $selectedTask = $tasks[[int]$choice - 1]

        switch ($selectedTask.type) {
            "SimpleCommand"         { _Invoke-SimpleCommand -Task $selectedTask }
            "DiskCleanup"           { _Invoke-DiskCleanup }
            "FindLargeFiles"        { _Invoke-FindLargeFiles -Task $selectedTask }
            "AnalyzeProcesses"      { _Invoke-AnalyzeProcesses -Task $selectedTask }
            "SetDNS"                { _Invoke-SetDNS -Task $selectedTask }
            "RecycleBinCleanup"     { _Invoke-RecycleBinCleanup -Task $selectedTask }
            "WindowsUpdateCleanup"  { _Invoke-WindowsUpdateCleanup -Task $selectedTask }
            default {
                Write-Styled -Type Error -Message "Tipo de tarea desconocido: '$($selectedTask.type)'"
                Pause-And-Return
            }
        }
    }

    $state.CleanupPerformed = $true # Placeholder state
    return $state
}
