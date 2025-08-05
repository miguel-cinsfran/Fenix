<#
.SYNOPSIS
    Módulo de Fase 4 para la instalación y configuración de WSL2.
.DESCRIPTION
    Contiene la lógica para verificar los prerrequisitos de WSL2, habilitar las
    características de Windows necesarias e instalar la distribución de Ubuntu.
.NOTES
    Versión: 1.0
    Autor: miguel-cinsfran
#>

function _Enable-WindowsFeature {
    param(
        [string]$FeatureName,
        [PSCustomObject]$state
    )
    Write-Styled -Type SubStep -Message "Habilitando la característica de Windows: '$FeatureName'..."
    # Este comando requiere reinicio.
    Dism.exe /Online /Enable-Feature /FeatureName:$FeatureName /All /NoRestart
    $state.ManualActions.Add("Se ha habilitado la característica '$FeatureName'. Se requiere un reinicio para completar la instalación.")
}

function _Test-WSLCommand {
    # Intenta ejecutar un comando WSL básico. Devuelve $true si es exitoso, $false en caso contrario.
    try {
        $result = wsl.exe --status
        # Si el comando se ejecuta pero devuelve un error conocido, también es un fallo.
        if ($result -match "El Subsistema de Windows para Linux no estß instalado") {
            return $false
        }
        return $true
    } catch {
        return $false
    }
}

function Invoke-Phase4_WSL {
    param([PSCustomObject]$state)
    if ($state.FatalErrorOccurred) { return $state }

    Show-Header -Title "FASE 4: Instalación de WSL2 (Ubuntu)"
    Write-Styled -Type Consent -Message "Esta fase instalará o actualizará WSL2 y la distribución de Ubuntu."
    if ((Read-Host "¿Confirma que desea proceder? (S/N)").Trim().ToUpper() -ne 'S') {
        Write-Styled -Type Warn -Message "Operación cancelada por el usuario."; Start-Sleep -Seconds 2; return $state
    }

    try {
        Write-Styled -Type Step -Message "Verificando el estado actual de WSL..."
        if (-not (_Test-WSLCommand)) {
            Write-Styled -Type Warn -Message "WSL no está instalado o no es funcional."
            Write-Styled -Type Step -Message "Verificando prerrequisitos de Windows (VirtualMachinePlatform y Subsystem-Linux)..."

            $featuresToEnable = @()
            $vmPlatform = Get-WindowsOptionalFeature -Online -FeatureName "VirtualMachinePlatform"
            if ($vmPlatform.State -ne 'Enabled') { $featuresToEnable += "VirtualMachinePlatform" }

            $wslSubsystem = Get-WindowsOptionalFeature -Online -FeatureName "Microsoft-Windows-Subsystem-Linux"
            if ($wslSubsystem.State -ne 'Enabled') { $featuresToEnable += "Microsoft-Windows-Subsystem-Linux" }

            if ($featuresToEnable.Count -gt 0) {
                Write-Styled -Type Warn -Message "Las siguientes características de Windows son necesarias y no están habilitadas:"
                $featuresToEnable | ForEach-Object { Write-Styled -Type Info -Message "  - $_" }
                Write-Styled -Type Consent -Message "El script puede intentar habilitarlas ahora. Esta operación requiere un REINICIO del sistema."
                if ((Read-Host "¿Autoriza al script a habilitar estas características? (S/N)").Trim().ToUpper() -eq 'S') {
                    foreach ($feature in $featuresToEnable) { _Enable-WindowsFeature -FeatureName $feature -state $state }
                    Write-Styled -Type Success -Message "Se han habilitado las características. Por favor, reinicie el equipo y vuelva a ejecutar esta fase."
                } else {
                    Write-Styled -Type Error -Message "Operación cancelada. No se pueden cumplir los prerrequisitos."
                }
                Pause-And-Return; return $state
            }

            Write-Styled -Type Success -Message "Todos los prerrequisitos de Windows ya están habilitados."
            Write-Styled -Type Step -Message "Procediendo con la instalación de WSL y la distribución de Ubuntu por defecto..."
            Write-Styled -Type Info -Message "Este proceso descargará componentes y puede tardar varios minutos."

            $installResult = Invoke-JobWithTimeout -ScriptBlock { wsl.exe --install } -Activity "Instalando WSL y Ubuntu" -TimeoutSeconds 1800
            if (-not $installResult.Success -or ($installResult.Output -join ' ') -match "Error") {
                throw "La instalación de WSL falló. Salida: $($installResult.Output | Out-String)"
            }

            Write-Styled -Type Success -Message "La instalación de WSL parece haber sido exitosa."
            $state.ManualActions.Add("WSL y Ubuntu han sido instalados. Se requiere un reinicio para completar la configuración.")
            Write-Styled -Type Warn -Message "Se requiere un REINICIO del sistema para finalizar la instalación de WSL."

        } else {
            Write-Styled -Type Success -Message "WSL ya está instalado y operativo."
            Write-Styled -Type Step -Message "Actualizando WSL al núcleo más reciente..."
            $updateResult = Invoke-JobWithTimeout -ScriptBlock { wsl.exe --update } -Activity "Actualizando WSL"
            if (-not $updateResult.Success) { Write-Styled -Type Warn -Message "No se pudo actualizar el núcleo de WSL. Puede que ya esté actualizado o no haya conexión."}
            else { Write-Styled -Type Success -Message "WSL actualizado correctamente." }

            Write-Styled -Type Step -Message "Verificando distribuciones instaladas..."
            $distros = wsl.exe --list
            if ($distros -match "No hay distribuciones instaladas.") {
                Write-Styled -Type Warn -Message "No se encontraron distribuciones de Linux."
                Write-Styled -Type Consent -Message "El script puede instalar la distribución recomendada (Ubuntu)."
                 if ((Read-Host "¿Desea instalar Ubuntu ahora? (S/N)").Trim().ToUpper() -eq 'S') {
                    $installDistroResult = Invoke-JobWithTimeout -ScriptBlock { wsl.exe --install --distribution Ubuntu } -Activity "Instalando Ubuntu" -TimeoutSeconds 600
                    if (-not $installDistroResult.Success) { throw "Error al instalar Ubuntu: $($installDistroResult.Error)" }
                    Write-Styled -Type Success -Message "Ubuntu instalado correctamente."
                 }
            } else {
                Write-Styled -Type Success -Message "Se encontraron las siguientes distribuciones:"
                $distros | ForEach-Object { Write-Styled -Type Info -Message "  $_" }
            }
        }

        Write-Styled -Type Success -Message "Fase 4 completada."
        $state.WSLInstalled = $true
    } catch {
        $state.FatalErrorOccurred = $true
        Write-Styled -Type Error -Message "Error fatal en la instalación de WSL: $($_.Exception.Message)"
    }

    Pause-And-Return
    return $state
}
