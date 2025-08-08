<#
.SYNOPSIS
    Módulo de Fase 1 para la erradicación de OneDrive.
.DESCRIPTION
    Contiene toda la lógica para la detección, desinstalación y purga de OneDrive
    del sistema, incluyendo la auditoría y reparación del Registro.
.NOTES
    Versión: 1.1
    Autor: miguel-cinsfran
    Revisión: Refactorizado para mayor legibilidad y robustez.
#>

function Repair-UserShellFolderPaths {
    Write-PhoenixStyledOutput -Type Step -Message "Auditando rutas de carpetas de usuario en el Registro..."
    $keysToAudit = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"
    )
    $issuesFound = @()

    foreach ($keyPath in $keysToAudit) {
        try {
            $item = Get-Item -Path $keyPath -ErrorAction Stop
            foreach ($valueName in $item.GetValueNames()) {
                $value = $item.GetValue($valueName)
                if ($value -is [string] -and $value -like "*OneDrive*") {
                    $issuesFound += [PSCustomObject]@{ Key = $keyPath; Name = $valueName; BadValue = $value }
                }
            }
        } catch {
            Write-PhoenixStyledOutput -Type Warn -Message "No se pudo auditar la clave del Registro: $keyPath"
        }
    }

    if ($issuesFound.Count -eq 0) {
        Write-PhoenixStyledOutput -Type Success -Message "Auditoría finalizada. No se encontraron rutas de OneDrive en el Registro."
        return
    }

    Write-PhoenixStyledOutput -Type Warn -Message "Se encontraron $($issuesFound.Count) rutas del Registro apuntando a OneDrive:"
    $issuesFound | ForEach-Object { Write-PhoenixStyledOutput -Type Info -Message "  $($_.Name) = '$($_.BadValue)'" }
    Write-PhoenixStyledOutput -Type Consent -Message "`nADVERTENCIA: La reparación de estas rutas es una operación de alto riesgo."

    if ((Request-MenuSelection -ValidChoices @('S','N') -PromptMessage "¿Autoriza al script a intentar corregir estas entradas?" -IsYesNoPrompt) -eq 'S') {
        Write-PhoenixStyledOutput -Type SubStep -Message "Reparando claves del Registro..."
        try {
            $issuesFound | ForEach-Object {
                # Reemplaza la parte de la ruta que contiene OneDrive con el perfil de usuario base.
                # Ejemplo: %USERPROFILE%\OneDrive\Documentos -> %USERPROFILE%\Documentos
                $pattern = [regex]::Escape($env:USERPROFILE) + '[\\/][^\\/]*OneDrive'
                $newValue = $_.BadValue -replace $pattern, $env:USERPROFILE

                # Si la ruta resultante es idéntica a la original, prueba un reemplazo más simple.
                if ($newValue -eq $_.BadValue) {
                    $newValue = $_.BadValue -replace 'OneDrive', ''
                }

                # Asegurarse de que el tipo de dato sea ExpandString para que %USERPROFILE% funcione.
                Set-ItemProperty -Path $_.Key -Name $_.Name -Value $newValue -Type ExpandString -ErrorAction Stop
                Write-PhoenixStyledOutput -Type Log -Message "Clave '$($_.Name)' actualizada a '$newValue'."
            }
            Write-PhoenixStyledOutput -Type Success -Message "Reparación de claves del Registro completada."
            Write-PhoenixStyledOutput -Type Info -Message "Reiniciando el Explorador de Windows para aplicar los cambios..."
            Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force
            # El explorador se reiniciará automáticamente.
            Confirm-SystemRestart
        } catch {
            Write-PhoenixStyledOutput -Type Error -Message "No se pudieron reparar las claves del Registro: $($_.Exception.Message)"
        }
    } else {
        Write-PhoenixStyledOutput -Type Error -Message "Consentimiento no otorgado. El Registro no ha sido modificado."
        Write-PhoenixStyledOutput -Type Warn -Message "ACCIÓN MANUAL REQUERIDA: Corrija manualmente las rutas del registro que apuntan a OneDrive."
    }
}

function Invoke-OneDrivePhase {
    Show-PhoenixHeader -Title "FASE 1: Erradicación de OneDrive"
    Write-PhoenixStyledOutput -Type Consent -Message "Esta fase detendrá procesos, desinstalará OneDrive y purgará sus rastros del sistema."
    if ((Request-MenuSelection -ValidChoices @('S','N') -PromptMessage "¿Confirma que desea proceder con la erradicación completa de OneDrive?" -IsYesNoPrompt) -ne 'S') {
        Write-PhoenixStyledOutput -Type Skip -Message "Operación cancelada por el usuario."
        Start-Sleep -Seconds 2
        return
    }

    try {
        # 1. Detener procesos de OneDrive
        Write-PhoenixStyledOutput -Type Step -Message "Deteniendo procesos de OneDrive..."
        $oneDriveProcesses = Get-Process OneDrive -ErrorAction SilentlyContinue
        if ($oneDriveProcesses) {
            $oneDriveProcesses | Stop-Process -Force -ErrorAction SilentlyContinue
            Write-PhoenixStyledOutput -Type Success -Message "Procesos de OneDrive detenidos."
        } else {
            Write-PhoenixStyledOutput -Type Info -Message "No se encontraron procesos de OneDrive en ejecución."
        }

        # 2. Lanzar desinstaladores
        Write-PhoenixStyledOutput -Type Step -Message "Ejecutando desinstaladores de OneDrive..."
        $uninstallerPaths = @(
            "$env:SystemRoot\SysWOW64\OneDriveSetup.exe",
            "$env:SystemRoot\System32\OneDriveSetup.exe"
        )
        $uninstallersFound = $uninstallerPaths | Where-Object { Test-Path $_ }

        if ($uninstallersFound) {
            foreach ($path in $uninstallersFound) {
                Write-PhoenixStyledOutput -Type SubStep -Message "Iniciando desinstalador: $path"
                try {
                    $process = Start-Process -FilePath $path -ArgumentList "/uninstall /silent /quiet" -Wait -PassThru -ErrorAction Stop
                    if ($process.ExitCode -ne 0) {
                        Write-PhoenixStyledOutput -Type Warn -Message "El desinstalador en '$path' finalizó con el código de salida: $($process.ExitCode)."
                    } else {
                        Write-PhoenixStyledOutput -Type SubStep -Message "El desinstalador en '$path' se ejecutó correctamente."
                    }
                } catch {
                    Write-PhoenixStyledOutput -Type Error -Message "Falló el lanzamiento del desinstalador en '$path': $($_.Exception.Message)"
                }
            }
            Write-PhoenixStyledOutput -Type Success -Message "Proceso de desinstalación finalizado."
        } else {
            Write-PhoenixStyledOutput -Type Warn -Message "No se encontraron ejecutables de desinstalación de OneDrive."
        }

        # 3. Aplicar GPO para deshabilitar OneDrive
        Write-PhoenixStyledOutput -Type Step -Message "Configurando Política de Grupo para deshabilitar OneDrive..."
        $osInfo = Get-CimInstance Win32_OperatingSystem
        # SKU 4 (Enterprise), 48 (Professional), 121 (Pro), 122 (Pro)
        if (@(4, 48, 121, 122) -contains $osInfo.OperatingSystemSKU) {
            try {
                $gpoPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive"
                if (-not (Test-Path $gpoPath)) {
                    New-Item -Path $gpoPath -Force -ErrorAction Stop | Out-Null
                }
                Set-ItemProperty -Path $gpoPath -Name "DisableFileSyncNGSC" -Value 1 -Type DWord -Force -ErrorAction Stop
                Write-PhoenixStyledOutput -Type Success -Message "Política de Grupo aplicada correctamente."
            } catch {
                Write-PhoenixStyledOutput -Type Error -Message "No se pudo aplicar la Política de Grupo: $($_.Exception.Message)"
            }
        } else {
            Write-PhoenixStyledOutput -Type Skip -Message "La edición de Windows no soporta GPO. Omitiendo este paso."
        }

        # 4. Purgar tareas programadas
        Write-PhoenixStyledOutput -Type Step -Message "Purgando tareas programadas de OneDrive..."
        $tasks = Get-ScheduledTask -TaskPath "\*" -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like "*OneDrive*" }
        if ($tasks) {
            $tasks | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
            Write-PhoenixStyledOutput -Type Success -Message "Tareas programadas de OneDrive eliminadas."
        } else {
            Write-PhoenixStyledOutput -Type Info -Message "No se encontraron tareas programadas de OneDrive."
        }

        # 5. Purgar claves del Explorador (Namespace)
        Write-PhoenixStyledOutput -Type Step -Message "Purgando claves de integración del Explorador..."
        $explorerKeys = @(
            "HKCR:\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}",
            "HKCR:\Wow6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}"
        )
        foreach ($key in $explorerKeys) {
            if (Test-Path $key) {
                try {
                    Remove-Item -Path $key -Recurse -Force -ErrorAction Stop
                    Write-PhoenixStyledOutput -Type SubStep -Message "Clave eliminada: $key"
                } catch {
                    Write-PhoenixStyledOutput -Type Warn -Message "No se pudo eliminar la clave '$key': $($_.Exception.Message)"
                }
            }
        }
        Write-PhoenixStyledOutput -Type Success -Message "Limpieza de claves del Explorador finalizada."

        # 6. Purgar accesos directos del menú de inicio
        Write-PhoenixStyledOutput -Type Step -Message "Purgando accesos directos del menú de inicio..."
        $startMenuPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\OneDrive.lnk"
        if (Test-Path $startMenuPath) {
            Remove-Item $startMenuPath -Force -ErrorAction SilentlyContinue
            Write-PhoenixStyledOutput -Type Success -Message "Acceso directo de OneDrive eliminado."
        } else {
            Write-PhoenixStyledOutput -Type Info -Message "No se encontró el acceso directo de OneDrive en el menú de inicio."
        }

        # 7. Auditar y reparar rutas del registro de usuario
        Repair-UserShellFolderPaths

        Write-PhoenixStyledOutput -Type Success -Message "La erradicación de OneDrive ha finalizado."
        Request-Continuation -Message "Presione Enter para volver al menú principal..."

    } catch {
        Write-PhoenixStyledOutput -Type Error -Message "Error fatal en la erradicación de OneDrive: $($_.Exception.Message)"
        Request-Continuation -Message "Presione Enter para volver al menú principal..."
    }
}

# Exportar únicamente las funciones destinadas al consumo público para evitar la
# exposición de helpers internos y cumplir con las mejores prácticas de modularización.
Export-ModuleMember -Function Invoke-OneDrivePhase
