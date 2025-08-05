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
    Invoke-JobWithTimeout -ScriptBlock ([scriptblock]::Create($Task.details.command)) -Activity $Task.description -TimeoutSeconds 600
    Write-Styled -Type Success -Message "Tarea '$($Task.description)' completada."
    Pause-And-Return
}

function _Invoke-DiskCleanup {
    Write-Styled -Type SubStep -Message "Analizando discos..."
    $drives = Get-CimInstance -ClassName Win32_Volume | Where-Object { $_.DriveType -eq 3 -and $_.DriveLetter }
    foreach ($drive in $drives) {
        $disk = Get-PhysicalDisk | Where-Object { $_.DeviceID -eq $drive.DriveLetter.Trim(":") }
        $mediaType = if ($disk.MediaType -eq 'SSD') { 'SSD' } else { 'HDD' }
        $action = if ($mediaType -eq 'SSD') { "ReTrim" } else { "Defrag" }
        Write-Styled -Type Info -Message "Optimizando unidad $($drive.DriveLetter) ($mediaType) con la acción: $action..."
        Optimize-Volume -DriveLetter $drive.DriveLetter.Trim(":") -Verbose -Defrag -ReTrim
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
    Write-Styled -Type SubStep -Message "Procesos con mayor consumo de CPU:"
    Get-Process | Sort-Object -Property CPU -Descending | Select-Object -First $Task.details.count | Format-Table -AutoSize
    Write-Styled -Type SubStep -Message "Procesos con mayor consumo de Memoria (MB):"
    Get-Process | Sort-Object -Property WorkingSet -Descending | Select-Object -First $Task.details.count | Format-Table -AutoSize
    Pause-And-Return
}

function _Invoke-SetDNS {
    param($Task)
    Write-Styled -Type SubStep -Message "Cambiando DNS a: $($Task.details.name) ($($Task.details.servers -join ', '))..."
    Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Set-DnsClientServerAddress -ServerAddresses ($Task.details.servers)
    Write-Styled -Type Success -Message "DNS cambiado correctamente."
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
            "SimpleCommand"    { _Invoke-SimpleCommand -Task $selectedTask }
            "DiskCleanup"      { _Invoke-DiskCleanup }
            "FindLargeFiles"   { _Invoke-FindLargeFiles -Task $selectedTask }
            "AnalyzeProcesses" { _Invoke-AnalyzeProcesses -Task $selectedTask }
            "SetDNS"           { _Invoke-SetDNS -Task $selectedTask }
            default {
                Write-Styled -Type Error -Message "Tipo de tarea desconocido: '$($selectedTask.type)'"
                Pause-And-Return
            }
        }
    }

    $state.CleanupPerformed = $true # Placeholder state
    return $state
}
