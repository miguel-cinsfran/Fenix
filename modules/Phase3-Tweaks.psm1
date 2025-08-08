<#
.SYNOPSIS
    Módulo de Fase 3 para la aplicación de optimizaciones y configuraciones del sistema.
.DESCRIPTION
    Presenta un menú interactivo de "tweaks" del sistema, con verificación de estado
    precisa y manejo de errores robusto, incluyendo manipulación de ACL para claves protegidas.
.NOTES
    Versión: 5.1
    Autor: miguel-cinsfran
    Revisión: Corregida la codificación de caracteres y mejorada la legibilidad.
#>

#region Tweak Type Helpers
# --- VERIFY HELPERS ---
function _Verify-Tweak-Registry {
    param($Tweak)
    $details = $Tweak.details
    try {
        $currentValue = Get-ItemPropertyValue -Path $details.path -Name $details.name -ErrorAction Stop
        if ("$currentValue" -eq "$($details.value)") { return "Aplicado" }
    } catch {
        # Si la propiedad no existe, definitivamente está pendiente de ser aplicada.
        return "Pendiente"
    }
    # Si existe pero no coincide, también está pendiente (de aplicar o revertir).
    return "Pendiente"
}
function _Verify-Tweak-ProtectedRegistry { param($Tweak) return _Verify-Tweak-Registry @PSBoundParameters }
function _Verify-Tweak-RegistryWithExplorerRestart { param($Tweak) return _Verify-Tweak-Registry @PSBoundParameters }

function _Verify-Tweak-AppxPackage {
    param($Tweak)
    if ($Tweak.details.state -eq 'Removed' -and (-not (Get-AppxPackage -Name $Tweak.details.packageName -ErrorAction SilentlyContinue))) {
        return "Aplicado"
    }
    return "Pendiente"
}

function _Verify-Tweak-PowerPlan {
    param($Tweak)
    if ((powercfg.exe /getactivescheme) -match $Tweak.details.schemeGuid) { return "Aplicado" }
    return "Pendiente"
}

function _Verify-Tweak-Service {
    param($Tweak)
    try {
        if ((Get-Service -Name $Tweak.details.name -ErrorAction Stop).StartType -eq $Tweak.details.startupType) { return "Aplicado" }
    } catch { return "Error" } # El servicio no existe, es un error de catálogo
    return "Pendiente"
}

function _Verify-Tweak-PowerShellCommand {
    param($Tweak)
    if ($Tweak.id -eq "DisableHibernation" -and (powercfg.exe /a) -match "La hibernación no está disponible.") {
        return "Aplicado"
    }
    # Para otros comandos, no hay forma genérica de saber, se asume pendiente.
    return "Pendiente"
}

# --- APPLY HELPERS ---
function _Apply-Tweak-Registry {
    param($Tweak)
    $details = $Tweak.details
    if (-not (Test-Path $details.path)) { New-Item -Path $details.path -Force | Out-Null }
    Set-ItemProperty -Path $details.path -Name $details.name -Value $details.value -Type $details.valueType -Force
}
function _Apply-Tweak-RegistryWithExplorerRestart { param($Tweak) _Apply-Tweak-Registry @PSBoundParameters }
function _Apply-Tweak-PowerPlan { param($Tweak) powercfg.exe /setactive $Tweak.details.schemeGuid }
function _Apply-Tweak-Service { param($Tweak) Set-Service -Name $Tweak.details.name -StartupType $Tweak.details.startupType }
function _Apply-Tweak-PowerShellCommand { param($Tweak) Invoke-Expression -Command "$($Tweak.details.command) $($Tweak.details.arguments)" }
function _Apply-Tweak-AppxPackage {
    param($Tweak)
    if ($Tweak.details.state -eq 'Removed') {
        $package = Get-AppxPackage -Name $Tweak.details.packageName -ErrorAction SilentlyContinue
        if ($package) {
            # Registrar los detalles del paquete antes de eliminarlo para trazabilidad.
            $logFile = Join-Path $PSScriptRoot "..\\removed_packages.log"
            $logEntry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Removed: $($package.Name) (Version: $($package.Version), ID: $($package.PackageFamilyName))"
            Add-Content -Path $logFile -Value $logEntry -Encoding UTF8

            $package | Remove-AppxPackage
        }
    }
}
function _Apply-Tweak-ProtectedRegistry {
    param($Tweak)
    $details = $Tweak.details
    $action = {
        _Apply-Tweak-Registry -Tweak $Tweak
    }
    Invoke-RegistryActionWithPrivileges -KeyPath $details.path -Action $action
}


# --- REVERT HELPERS ---
function _Revert-Tweak-Registry {
    param($Tweak)
    $details = $Tweak.details
    $revertDetails = $Tweak.revert_details

    if ($revertDetails.action -eq 'delete_value') {
        if (Test-Path -Path $details.path) { Remove-ItemProperty -Path $details.path -Name $details.name -Force -ErrorAction SilentlyContinue }
    } elseif ($revertDetails.action -eq 'delete_key') {
        if (Test-Path -Path $revertDetails.path) { Remove-Item -Path $revertDetails.path -Recurse -Force -ErrorAction SilentlyContinue }
    } else {
        Set-ItemProperty -Path $details.path -Name $details.name -Value $revertDetails.value -Type $details.valueType -Force
    }
}
function _Revert-Tweak-RegistryWithExplorerRestart { param($Tweak) _Revert-Tweak-Registry @PSBoundParameters }
function _Revert-Tweak-PowerPlan { param($Tweak) powercfg.exe /setactive $Tweak.revert_details.schemeGuid }
function _Revert-Tweak-Service { param($Tweak) Set-Service -Name $Tweak.details.name -StartupType $Tweak.revert_details.startupType }
function _Revert-Tweak-PowerShellCommand { param($Tweak) Invoke-Expression -Command "$($Tweak.revert_details.command) $($Tweak.revert_details.arguments)" }
function _Revert-Tweak-AppxPackage { param($Tweak) Write-PhoenixStyledOutput -Type Warn -Message "La reversión para '$($Tweak.description)' no está soportada." }
function _Revert-Tweak-ProtectedRegistry {
    param($Tweak)
    $details = $Tweak.details
    $action = {
        _Revert-Tweak-Registry -Tweak $Tweak
    }
    Invoke-RegistryActionWithPrivileges -KeyPath $details.path -Action $action
}

function Invoke-SoftwareSearchAndInstall {
    [CmdletBinding()]
    param()

    Show-PhoenixHeader -Title "Búsqueda e Instalación de Paquetes (Winget)"
    $searchTerm = Read-Host "Introduzca el nombre o ID del paquete a buscar"
    if (-not $searchTerm) { return }

    Write-PhoenixStyledOutput -Type Info -Message "Buscando '$($searchTerm)' con Winget..."
    $searchResult = Invoke-NativeCommandWithOutputCapture -Executable "winget" -ArgumentList "search `"$searchTerm`" --accept-source-agreements" -Activity "Buscando en Winget"

    if (-not $searchResult.Success -or $searchResult.Output -match "No package found matching input criteria") {
        Write-PhoenixStyledOutput -Type Error -Message "No se encontraron paquetes que coincidan con '$searchTerm'."
        Request-Continuation -Message "Presione Enter para continuar..."
        return
    }

    Write-Host $searchResult.Output
    Write-PhoenixStyledOutput -Type Consent -Message "Se encontraron los paquetes de arriba."
    $idToInstall = Read-Host "Escriba el ID exacto del paquete que desea instalar (o presione Enter para cancelar)"

    if ($idToInstall) {
        Invoke-NativeCommandWithOutputCapture -Executable "winget" -ArgumentList "install --id $idToInstall --accept-package-agreements --accept-source-agreements" -Activity "Instalando $idToInstall"
    }
}
#endregion

function Invoke-TweakAction {
    param(
        [string]$Action, # "Apply" or "Revert"
        [PSCustomObject]$Tweak
    )
    $actionVerb = if ($Action -eq "Apply") { "Aplicando" } else { "Revirtiendo" }
    Write-PhoenixStyledOutput -Message "$actionVerb ajuste para '$($Tweak.description)'..." -NoNewline

    $needsExplorerRestart = $Tweak.type -like "*WithExplorerRestart"
    if ($needsExplorerRestart) { Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 1 }

    $success = $false
    try {
        $functionName = "_${Action}-Tweak-$($Tweak.type)"
        if (-not (Get-Command $functionName -ErrorAction SilentlyContinue)) {
            throw "Función de motor no encontrada: $functionName"
        }
        & $functionName -Tweak $Tweak
        $success = $true
        Write-Host " [ÉXITO]" -F $Global:Theme.Success
    } catch {
        Write-Host " [FALLO]" -F $Global:Theme.Error
        Write-PhoenixStyledOutput -Type Log -Message "Error al $actionVerb '$($Tweak.id)': $($_.Exception.Message)"
    }

    if ($needsExplorerRestart) { Start-Process explorer.exe | Out-Null }
    if ($Tweak.rebootRequired) { $global:RebootIsPending = $true }
    return $success
}

function Invoke-TweaksPhase {
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
        $tweaks = $catalogJson.items
    } catch {
        Write-PhoenixStyledOutput -Type Error -Message "Fallo CRÍTICO al leer o procesar el catálogo de tweaks: $($_.Exception.Message)"
        Request-Continuation -Message "Presione Enter para volver al menú principal..."
        return
    }

    $exitMenu = $false
    while (-not $exitMenu) {
        Show-PhoenixHeader -Title "FASE 3: Optimización del Sistema"

        $tweakStatusList = @()
        foreach ($tweak in $tweaks) {
            $verifyFunctionName = "_Verify-Tweak-$($tweak.type)"
            $status = "Error de Motor"
            if (Get-Command $verifyFunctionName -ErrorAction SilentlyContinue) {
                $status = & $verifyFunctionName -Tweak $tweak
            }
            if (-not $tweak.PSObject.Properties.Match('revert_details') -and $status -eq 'Aplicado') {
                $status = "Aplicado (No Reversible)"
            }
            $tweakStatusList += [PSCustomObject]@{ Tweak = $tweak; Status = $status }
        }

        # Construir y mostrar el menú estandarizado
        $menuItems = $tweakStatusList | ForEach-Object {
            [PSCustomObject]@{
                Description = $_.Tweak.description
                Status      = $_.Status
            }
        }
        $actionOptions = [ordered]@{
            'A' = 'Aplicar TODOS los pendientes.'
            'D' = 'Deshacer TODOS los aplicados.'
            'R' = 'Refrescar la lista.'
            '0' = 'Volver al Menú Principal.'
        }
        $choices = Show-PhoenixStandardMenu -Title "FASE 3: Optimización del Sistema" -MenuItems $menuItems -ActionOptions $actionOptions

        $actionTaken = $false

        # Procesar acciones de una sola letra que afectan a toda la operación
        if ($choices -contains '0') { $exitMenu = $true; continue }
        if ($choices -contains 'R') { continue }
        if ($choices -contains 'A') {
            $items = $tweakStatusList | Where-Object { $_.Status -eq 'Pendiente' }
            if ($items.Count -eq 0) { Write-PhoenixStyledOutput -Type Info -Message "No hay ajustes pendientes para aplicar."; Start-Sleep -Seconds 2 }
            else {
                foreach($item in $items) { Invoke-TweakAction -Action "Apply" -Tweak $item.Tweak }
                $actionTaken = $true
            }
            if ($actionTaken) { continue }
        }
        if ($choices -contains 'D') {
            $items = $tweakStatusList | Where-Object { $_.Status -eq 'Aplicado' }
            if ($items.Count -eq 0) { Write-PhoenixStyledOutput -Type Info -Message "No hay ajustes aplicados para revertir."; Start-Sleep -Seconds 2 }
            else {
                 if ((Request-MenuSelection -ValidChoices @('S','N') -PromptMessage "¿Está seguro de que desea revertir $($items.count) ajustes?" -IsYesNoPrompt) -eq 'S') {
                    foreach($item in $items) { Invoke-TweakAction -Action "Revert" -Tweak $item.Tweak }
                    $actionTaken = $true
                 }
            }
            if ($actionTaken) { continue }
        }

        # Procesar selecciones numéricas
        $numericActions = $choices | ForEach-Object { [int]$_ } | Sort-Object
        foreach ($choice in $numericActions) {
            $selectedItem = $tweakStatusList[$choice - 1]
            if ($selectedItem.Status -eq 'Pendiente') {
                Invoke-TweakAction -Action "Apply" -Tweak $selectedItem.Tweak
                $actionTaken = $true
            } elseif ($selectedItem.Status -eq 'Aplicado') {
                if ((Request-MenuSelection -ValidChoices @('S','N') -PromptMessage "¿Está seguro de que desea revertir '$($selectedItem.Tweak.description)'?" -IsYesNoPrompt) -eq 'S') {
                    Invoke-TweakAction -Action "Revert" -Tweak $selectedItem.Tweak
                    $actionTaken = $true
                }
            } else {
                if ($selectedItem.Status -eq 'Aplicado (No Reversible)') {
                    if ((Request-MenuSelection -ValidChoices @('S','N') -PromptMessage "Este ajuste no se puede revertir. ¿Desea intentar buscar e instalar el paquete original?" -IsYesNoPrompt) -eq 'S') {
                        Invoke-SoftwareSearchAndInstall
                        $actionTaken = $true
                    }
                } else {
                    Write-PhoenixStyledOutput -Type Warn -Message "Este ajuste no se puede cambiar (Estado: $($selectedItem.Status))"
                    Start-Sleep -Seconds 2
                }
            }
        }

        if ($actionTaken) {
            # No es necesario hacer nada aquí. El bucle se reiniciará automáticamente,
            # refrescando la lista de estados y proporcionando una experiencia más fluida.
        }
    }
}

Export-ModuleMember -Function Invoke-TweaksPhase
