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

function Invoke-Phase4_WSL {
    param([PSCustomObject]$state)
    if ($state.FatalErrorOccurred) { return $state }

    Show-Header -Title "FASE 4: Instalación de WSL2 (Ubuntu)"
    Write-Styled -Type Consent -Message "Esta fase instalará o actualizará WSL2 y la distribución de Ubuntu."
    if ((Read-Host "¿Confirma que desea proceder? (S/N)").Trim().ToUpper() -ne 'S') {
        Write-Styled -Type Warn -Message "Operación cancelada por el usuario."; Start-Sleep -Seconds 2; return $state
    }

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
            foreach ($feature in $featuresToEnable) {
                _Enable-WindowsFeature -FeatureName $feature -state $state
            }
            Write-Styled -Type Success -Message "Se han habilitado las características. Por favor, reinicie el equipo y vuelva a ejecutar esta fase."
            Pause-And-Return
            return $state
        } else {
            Write-Styled -Type Error -Message "Operación cancelada. No se pueden cumplir los prerrequisitos."
            Pause-And-Return
            return $state
        }
    } else {
        Write-Styled -Type Success -Message "Todos los prerrequisitos de Windows ya están habilitados."
    }

    try {
        Write-Styled -Type Step -Message "Actualizando WSL al núcleo más reciente..."
        $updateResult = Invoke-JobWithTimeout -ScriptBlock { wsl --update } -Activity "Actualizando WSL"
        if (-not $updateResult.Success) { throw "Error al actualizar WSL: $($updateResult.Error)" }
        Write-Styled -Type Success -Message "WSL actualizado correctamente."

        Write-Styled -Type Step -Message "Estableciendo WSL2 como la versión por defecto..."
        Invoke-JobWithTimeout -ScriptBlock { wsl --set-default-version 2 } -Activity "Configurando WSL2" | Out-Null

        Write-Styled -Type Step -Message "Instalando la distribución de Ubuntu..."
        $installResult = Invoke-JobWithTimeout -ScriptBlock { wsl --install --distribution Ubuntu } -Activity "Instalando Ubuntu" -TimeoutSeconds 600
        if (-not $installResult.Success) { throw "Error al instalar Ubuntu: $($installResult.Error)" }
        Write-Styled -Type Success -Message "Ubuntu instalado correctamente."

        Write-Styled -Type Success -Message "Fase 4 completada."
        $state.WSLInstalled = $true
    } catch {
        $state.FatalErrorOccurred = $true
        Write-Styled -Type Error -Message "Error fatal en la instalación de WSL: $($_.Exception.Message)"
    }

    Pause-And-Return
    return $state
}
