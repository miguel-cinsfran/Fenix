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

    try {
        Write-Styled -Type Step -Message "Verificando el estado actual de WSL..."
        $statusResult = Invoke-NativeCommand -Executable "wsl.exe" -ArgumentList "--status" -FailureStrings "no está instalado" -Activity "Chequeando estado de WSL"

        if (-not $statusResult.Success) {
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
                if ((Read-Host "¿Autoriza al script a habilitar estas características? (S/N)").Trim().ToUpper() -eq 'S') {
                    foreach ($feature in $featuresToEnable) { _Enable-WindowsFeature -FeatureName $feature -state $state }
                    Write-Styled -Type Error -Message "ACCIÓN REQUERIDA: Se han habilitado las características de Windows necesarias."
                    Write-Styled -Type Error -Message "DEBE REINICIAR EL EQUIPO para poder continuar con la instalación de WSL."
                } else {
                    Write-Styled -Type Error -Message "Operación cancelada. No se pueden cumplir los prerrequisitos."
                }
                Pause-And-Return
                return $state
            }

            Write-Styled -Type Success -Message "Todos los prerrequisitos de Windows ya están habilitados."
            Write-Styled -Type Step -Message "Procediendo con la instalación de WSL y la distribución de Ubuntu por defecto..."
            $installResult = Invoke-NativeCommand -Executable "wsl.exe" -ArgumentList "--install" -FailureStrings "Error" -Activity "Instalando WSL y Ubuntu"
            if (-not $installResult.Success) {
                throw "La instalación de WSL falló. Salida: $($installResult.Output)"
            }

            Write-Styled -Type Success -Message "La instalación de WSL parece haber sido exitosa."
            $state.ManualActions.Add("WSL y Ubuntu han sido instalados. Se requiere un reinicio para completar la configuración.")
            Write-Styled -Type Warn -Message "Se requiere un REINICIO del sistema para finalizar la instalación de WSL."

        } else {
            Write-Styled -Type Success -Message "WSL ya está instalado y operativo."
            Write-Styled -Type Step -Message "Actualizando WSL al núcleo más reciente..."
            Invoke-NativeCommand -Executable "wsl.exe" -ArgumentList "--update" -Activity "Actualizando WSL" | Out-Null

            Write-Styled -Type Step -Message "Verificando distribuciones instaladas..."
            $listResult = Invoke-NativeCommand -Executable "wsl.exe" -ArgumentList "--list" -Activity "Listando distribuciones"
            if ($listResult.Output -match "No hay distribuciones instaladas") {
                Write-Styled -Type Warn -Message "No se encontraron distribuciones de Linux."
                if ((Read-Host "¿Desea instalar la distribución recomendada (Ubuntu) ahora? (S/N)").Trim().ToUpper() -eq 'S') {
                    $installDistroResult = Invoke-NativeCommand -Executable "wsl.exe" -ArgumentList "--install --distribution Ubuntu" -FailureStrings "Error" -Activity "Instalando Ubuntu"
                    if (-not $installDistroResult.Success) {
                        throw "Error al instalar Ubuntu: $($installDistroResult.Output)"
                    }
                    Write-Styled -Type Success -Message "Ubuntu instalado correctamente."
                }
            } else {
                Write-Styled -Type Success -Message "Se encontraron las siguientes distribuciones:"
                $listResult.Output | ForEach-Object { if ($_ -and $_ -notmatch "instalar distribuciones") { Write-Styled -Type Info -Message "  $_" } }
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
