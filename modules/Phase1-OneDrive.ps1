<#
.SYNOPSIS
    Módulo de Fase 1 para la erradicación de OneDrive.
.DESCRIPTION
    Contiene toda la lógica para la detección, desinstalación y purga de OneDrive
    del sistema, incluyendo la auditoría y reparación del Registro.
.NOTES
    Versión: 1.0
    Autor: miguel-cinsfran
#>

function Audit-And-Repair-UserShellFolders {
    param([PSCustomObject]$state)
    Write-Styled -Type SubStep -Message "Auditando rutas de carpetas de usuario en el Registro..."
    $keysToAudit = @("HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders", "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders")
    $issuesFound = @()
    foreach ($keyPath in $keysToAudit) {
        $item = Get-Item -Path $keyPath
        foreach ($valueName in $item.GetValueNames()) {
            $value = $item.GetValue($valueName)
            if ($value -is [string] -and $value -like "*OneDrive*") {
                $issuesFound += [PSCustomObject]@{ Key = $keyPath; Name = $valueName; BadValue = $value }
            }
        }
    }
    if ($issuesFound.Count -eq 0) { Write-Styled -Type Success -Message "No se encontraron rutas de OneDrive en el Registro."; return }
    Write-Styled -Type Warn -Message "Se encontraron $($issuesFound.Count) rutas del Registro apuntando a OneDrive:"
    $issuesFound | ForEach-Object { Write-Styled -Type Info -Message "  $($_.Name) = '$($_.BadValue)'" }
    Write-Styled -Type Consent -Message "`nADVERTENCIA: La reparación de estas rutas es una operación de alto riesgo."
    if ((Read-Host "¿Autoriza al script a intentar corregir estas entradas? (S/N)").Trim().ToUpper() -eq 'S') {
        Write-Styled -Message "Reparando claves del Registro..." -NoNewline
        $issuesFound | ForEach-Object { $pattern = [regex]::Escape($env:USERPROFILE) + '.*\\OneDrive'; $newValue = $_.BadValue -replace $pattern, "$env:USERPROFILE"; Set-ItemProperty -Path $_.Key -Name $_.Name -Value $newValue -Type ExpandString }
        Write-Host " [ÉXITO]" -F $Global:Theme.Success
        Write-Styled -Message "Reiniciando Explorador para aplicar cambios..." -NoNewline; Get-Process explorer | Stop-Process -Force; Write-Host " [ÉXITO]" -F $Global:Theme.Success
        $state.ManualActions.Add("Se han corregido rutas del Registro. Se recomienda reiniciar el equipo para garantizar la correcta aplicación de los cambios.")
    } else {
        Write-Styled -Type Error -Message "Consentimiento no otorgado. El Registro no ha sido modificado."
        $state.ManualActions.Add("El script detectó rutas de usuario apuntando a OneDrive, pero no se le dio permiso para corregirlas.")
    }
}

function Invoke-Phase1_OneDrive {
    param([PSCustomObject]$state)
    if ($state.FatalErrorOccurred) { return $state } # Contrato de propagación de errores

    Show-Header -Title "FASE 1: Erradicación de OneDrive"
    Write-Styled -Type Consent -Message "Esta fase detendrá procesos, desinstalará OneDrive y purgará sus rastros del sistema."
    if ((Read-Host "¿Confirma que desea proceder con la erradicación completa de OneDrive? (S/N)").Trim().ToUpper() -ne 'S') {
        Write-Styled -Type Warn -Message "Operación cancelada por el usuario."; Start-Sleep -Seconds 2; return $state
    }
    try {
        Write-Styled -Message "Deteniendo procesos de OneDrive..." -NoNewline; Get-Process OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue; Write-Host " [ÉXITO]" -F $Global:Theme.Success
        Write-Styled -Message "Lanzando desinstaladores en segundo plano..."
        $uninstallerPaths = @("$env:SystemRoot\SysWOW64\OneDriveSetup.exe", "$env:SystemRoot\System32\OneDriveSetup.exe")
        $uninstallJobs = @()
        foreach ($path in $uninstallerPaths) { if (Test-Path $path) { Write-Styled -Type SubStep -Message "Lanzando trabajo para: $path"; $job = Start-Job -ScriptBlock { param($p) Start-Process $p -ArgumentList "/uninstall /silent" -Wait } -ArgumentList $path; $uninstallJobs += $job } }
        if ($uninstallJobs.Count -gt 0) { Write-Styled -Type Info -Message "Esperando finalización de desinstaladores..."; Wait-Job -Job $uninstallJobs | Out-Null; $uninstallJobs | ForEach-Object { Receive-Job $_; Remove-Job $_ }; Write-Styled -Type Success -Message "Todos los trabajos de desinstalación han finalizado." } else { Write-Styled -Type Warn -Message "No se encontraron desinstaladores de OneDrive." }
        $osInfo = Get-CimInstance Win32_OperatingSystem
        if (@(4, 48, 121, 122) -contains $osInfo.OperatingSystemSKU) { Write-Styled -Message "Aplicando Política de Grupo para deshabilitar OneDrive..." -NoNewline; $gpoPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive"; if (-not (Test-Path $gpoPath)) { New-Item -Path $gpoPath -Force | Out-Null }; Set-ItemProperty -Path $gpoPath -Name "DisableFileSyncNGSC" -Value 1 -Type DWord -Force; Write-Host " [ÉXITO]" -F $Global:Theme.Success } else { Write-Styled -Type Warn -Message "La edición de Windows no soporta GPO. Omitiendo." }
        Write-Styled -Message "Purgando tareas programadas..." -NoNewline; Get-ScheduledTask -TaskPath "\*" | Where-Object { $_.TaskName -like "*OneDrive*" } | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue; Write-Host " [ÉXITO]" -F $Global:Theme.Success
        Write-Styled -Message "Purgando claves del Explorador..." -NoNewline; @("HKCR:\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}", "HKCR:\Wow6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}") | ForEach-Object { if (Test-Path $_) { Remove-Item -Path $_ -Recurse -Force } }; Write-Host " [ÉXITO]" -F $Global:Theme.Success
        Write-Styled -Message "Purgando accesos directos..." -NoNewline; $startMenuPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\OneDrive.lnk"; if (Test-Path $startMenuPath) { Remove-Item $startMenuPath -Force }; Write-Host " [ÉXITO]" -F $Global:Theme.Success
        Audit-And-Repair-UserShellFolders -state $state
        $state.OneDriveErradicated = $true
    } catch {
        $state.FatalErrorOccurred = $true
        Write-Styled -Type Error -Message "Error fatal en la erradicación de OneDrive: $($_.Exception.Message)"
    }
    return $state
}