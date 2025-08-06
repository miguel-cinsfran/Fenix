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
    param([string]$FeatureName)
    Write-Styled -Type SubStep -Message "Habilitando la característica de Windows: '$FeatureName'..."
    $result = Invoke-NativeCommand -Executable "Dism.exe" -ArgumentList "/Online /Enable-Feature /FeatureName:$FeatureName /All /NoRestart" -Activity "Habilitando $FeatureName" -ProgressRegex '\s(\d+)\s*%'
    if (-not $result.Success) {
        throw "DISM falló al intentar habilitar '$FeatureName'. Salida: $($result.Output)"
    }
    Write-Styled -Type Warn -Message "Se ha habilitado la característica '$FeatureName'. Se requiere un reinicio para completar la instalación."
}

function _Handle-Distro-Installation {
    Write-Styled -Type Step -Message "Verificando distribuciones instaladas..."
    $listResult = Invoke-NativeCommand -Executable "wsl.exe" -ArgumentList "--list" -Activity "Listando distribuciones"

    # Si no hay distros, intentar instalar Ubuntu por defecto
    if ($listResult.Output -match "No hay distribuciones instaladas" -or -not $listResult.Success) {
        Write-Styled -Type Warn -Message "No se encontraron distribuciones de Linux instaladas."
        Write-Styled -Type Consent -Message "El script puede intentar instalar la distribución 'Ubuntu' por defecto."
        if ((Invoke-MenuPrompt -ValidChoices @('S','N') -PromptMessage "¿Desea continuar con la instalación de Ubuntu?") -eq 'S') {
            $installResult = Invoke-NativeCommand -Executable "wsl.exe" -ArgumentList "--install --distribution Ubuntu" -FailureStrings "Error" -Activity "Instalando Ubuntu" -IdleTimeoutEnabled:$false -ProgressRegex '\s(\d+)\s*%'
            if (-not $installResult.Success) {
                throw "Error al instalar Ubuntu: $($installResult.Output)"
            }
            Write-Styled -Type Success -Message "Ubuntu instalado correctamente."
            # Refrescar la lista para mostrar la nueva distro
            $listResult = Invoke-NativeCommand -Executable "wsl.exe" -ArgumentList "--list" -Activity "Listando distribuciones"
        }
    }

    # Mostrar las distribuciones encontradas (si las hay)
    if ($listResult.Success -and $listResult.Output -notmatch "No hay distribuciones instaladas") {
        Write-Styled -Type Success -Message "Se encontraron las siguientes distribuciones:"
        $listResult.Output | ForEach-Object { if ($_ -and $_ -notmatch "instalar distribuciones") { Write-Styled -Type Info -Message "  $_" } }
    }

    # Preguntar si se desea instalar OTRA distribución
    if ((Invoke-MenuPrompt -ValidChoices @('S','N') -PromptMessage "¿Desea buscar e instalar otra distribución de Linux?") -eq 'S') {
        $onlineListResult = Invoke-NativeCommand -Executable "wsl.exe" -ArgumentList "--list --online" -Activity "Buscando distribuciones online"
        if ($onlineListResult.Success) {
            Write-Styled -Type Info -Message "Distribuciones disponibles:"
            Write-Host ($onlineListResult.Output)
            $distroToInstall = Read-Host "Escriba el nombre de la distribución que desea instalar (o presione Enter para cancelar)"
            if ($distroToInstall) {
                $installResult = Invoke-NativeCommand -Executable "wsl.exe" -ArgumentList "--install --distribution $distroToInstall" -FailureStrings "Error" -Activity "Instalando $distroToInstall" -IdleTimeoutEnabled:$false -ProgressRegex '\s(\d+)\s*%'
                if (-not $installResult.Success) {
                    throw "Error al instalar ${distroToInstall}: $($installResult.Output)"
                }
                Write-Styled -Type Success -Message "${distroToInstall} instalado correctamente."
            }
        }
    }
}

function Invoke-Phase4_WSL {
    Show-Header -Title "FASE 4: Instalación de WSL2 (Ubuntu)"
    Write-Styled -Type Consent -Message "Esta fase instalará o actualizará WSL2 y la distribución de Ubuntu."
    if ((Invoke-MenuPrompt -ValidChoices @('S','N') -PromptMessage "Confirma que desea proceder?") -ne 'S') {
        Write-Styled -Type Warn -Message "Operación cancelada por el usuario."; Start-Sleep -Seconds 2; return
    }

    try {
        Write-Styled -Type Step -Message "Verificando el estado actual de WSL..."
        $statusResult = Invoke-NativeCommand -Executable "wsl.exe" -ArgumentList "--status" -FailureStrings "no está instalado" -Activity "Chequeando estado de WSL"

        if (-not $statusResult.Success) {
            Write-Styled -Type Warn -Message "WSL no está instalado o no es funcional."
            Write-Styled -Type Step -Message "Verificando prerrequisitos de Windows (VirtualMachinePlatform y Subsystem-Linux)..."

            $featuresToEnable = @()
            if ((Get-WindowsOptionalFeature -Online -FeatureName "VirtualMachinePlatform").State -ne 'Enabled') { $featuresToEnable += "VirtualMachinePlatform" }
            if ((Get-WindowsOptionalFeature -Online -FeatureName "Microsoft-Windows-Subsystem-Linux").State -ne 'Enabled') { $featuresToEnable += "Microsoft-Windows-Subsystem-Linux" }

            if ($featuresToEnable.Count -gt 0) {
                Write-Styled -Type Warn -Message "Las siguientes características de Windows son necesarias y no están habilitadas:"
                $featuresToEnable | ForEach-Object { Write-Styled -Type Info -Message "  - $_" }
                if ((Invoke-MenuPrompt -ValidChoices @('S','N') -PromptMessage "Autoriza al script a habilitar estas características?") -eq 'S') {
                    foreach ($feature in $featuresToEnable) { _Enable-WindowsFeature -FeatureName $feature }
                    Invoke-RestartPrompt
                } else {
                    Write-Styled -Type Error -Message "Operación cancelada. No se pueden cumplir los prerrequisitos."
                    Pause-And-Return
                }
                return
            }

            Write-Styled -Type Success -Message "Todos los prerrequisitos de Windows ya están habilitados."
            Write-Styled -Type Step -Message "Procediendo con la instalación de WSL y la distribución de Ubuntu por defecto..."
            $installResult = Invoke-NativeCommand -Executable "wsl.exe" -ArgumentList "--install" -FailureStrings "Error" -Activity "Instalando WSL y Ubuntu" -IdleTimeoutEnabled:$false -ProgressRegex '\s(\d+)\s*%'
            if (-not $installResult.Success) {
                throw "La instalación de WSL falló. Salida: $($installResult.Output)"
            }

            Write-Styled -Type Success -Message "La instalación de WSL parece haber sido exitosa."
            Write-Styled -Type Warn -Message "Se requiere un REINICIO del sistema para finalizar la instalación de WSL."

        } else {
            Write-Styled -Type Success -Message "WSL ya está instalado y operativo."
            Write-Styled -Type Step -Message "Actualizando WSL al núcleo más reciente..."
            Invoke-NativeCommand -Executable "wsl.exe" -ArgumentList "--update" -Activity "Actualizando WSL" | Out-Null
            _Handle-Distro-Installation
        }
        Write-Styled -Type Success -Message "Fase 4 completada."
    } catch {
        Write-Styled -Type Error -Message "Error fatal en la instalación de WSL: $($_.Exception.Message)"
    }
    Pause-And-Return
}