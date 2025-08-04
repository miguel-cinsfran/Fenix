<#
.SYNOPSIS
    Módulo de Fase 3 para la aplicación de optimizaciones y configuraciones del sistema.
.DESCRIPTION
    Presenta un menú interactivo de "tweaks" del sistema, con verificación de estado
    precisa y manejo de errores robusto (en teoría), incluyendo manipulación de ACL para claves protegidas.
.NOTES
    Versión: 3.2
    Autor: miguel-cinsfran
#>

# --- FUNCIONES DE VERIFICACIÓN PRECISA (VERIFY) ---
function Verify-RegistryTweak {
    param([PSCustomObject]$Tweak)
    $details = $Tweak.details
    try {
        # Si la clave o el valor no existen, Get-ItemPropertyValue lanza una excepción que se captura abajo.
        $currentValue = Get-ItemPropertyValue -Path $details.path -Name $details.name -ErrorAction Stop

        # Compara el valor actual con el deseado.
        if ("$currentValue" -eq "$($details.value)") {
            return "Aplicado" # El valor ya es el correcto.
        } else {
            return "Pendiente" # El valor existe pero es diferente.
        }
    } catch [System.Management.Automation.ItemNotFoundException] {
        # Significa que la clave o el valor no existen. Para un Tweak que busca CREAR un valor,
        # este estado es 'Pendiente'. Esto es correcto para todos los tweaks actuales del catálogo.
        return "Pendiente"
    } catch {
        # Captura cualquier otro error inesperado (ej. permisos).
        Write-Styled -Type Log -Message "Error al verificar el Tweak '$($Tweak.id)': $($_.Exception.Message)"
        return "Error"
    }
}

function Verify-AppxPackage {
    param([PSCustomObject]$Tweak)
    $package = Get-AppxPackage -Name $Tweak.details.packageName -ErrorAction SilentlyContinue
    if ($Tweak.details.state -eq 'Removed') {
        if ($null -eq $package) { return "Aplicado" }
        return "Pendiente"
    }
    return "Error" # Estado no soportado.
}

function Verify-PowerPlanTweak {
    param([PSCustomObject]$Tweak)
    if ((powercfg.exe /getactivescheme) -match $Tweak.details.schemeGuid) { return "Aplicado" }
    return "Pendiente"
}

function Verify-ServiceTweak {
    param([PSCustomObject]$Tweak)
    try {
        $service = Get-CimInstance -ClassName Win32_Service -Filter "Name = '$($Tweak.details.name)'" -ErrorAction Stop
        if ($service.StartMode -eq $Tweak.details.startupType) { return "Aplicado" }
        return "Pendiente"
    } catch { return "NoEncontrado" }
}

function Verify-PowerShellCommandTweak {
    param([PSCustomObject]$Tweak)
    # Esta verificación sigue siendo específica porque depende de la salida de un comando.
    if ($Tweak.id -eq "DisableHibernation" -and (powercfg.exe /a) -match "La hibernación no está disponible.") { return "Aplicado" }
    return "Pendiente"
}


# --- FUNCIONES DE APLICACIÓN (APPLY) ---
function Apply-ProtectedRegistryTweak {
    param([PSCustomObject]$Tweak)
    Write-Styled -Message "Aplicando ajuste protegido para '$($Tweak.description)'..." -NoNewline
    $details = $Tweak.details
    $success = $false
    $keyPath = $details.path
    $originalSddl = $null

    try {
        if (-not (Test-Path $keyPath)) {
            New-Item -Path $keyPath -Force | Out-Null
        }

        # --- Tomar Control ---
        $acl = Get-Acl -Path $keyPath
        $originalSddl = $acl.Sddl # Guardar el estado original completo como SDDL.

        $administratorsSid = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
        $acl.SetOwner($administratorsSid)

        $rule = New-Object System.Security.AccessControl.RegistryAccessRule($administratorsSid, "FullControl", "Allow")
        $acl.AddAccessRule($rule)

        Set-Acl -Path $keyPath -AclObject $acl -ErrorAction Stop

        # --- Realizar Operación ---
        New-ItemProperty -Path $details.path -Name $details.name -Value $details.value -PropertyType $details.valueType -Force -ErrorAction Stop

        $success = $true
        Write-Host " [ÉXITO]" -F $Global:Theme.Success

    } catch {
        Write-Host " [FALLO]" -F $Global:Theme.Error
        Write-Styled -Type Log -Message "Error al aplicar '$($Tweak.id)': $($_.Exception.Message)"
    } finally {
        # --- Restaurar Permisos Originales ---
        if ($originalSddl) {
            try {
                # Crear un nuevo objeto ACL desde el SDDL guardado y aplicarlo.
                $restoredAcl = New-Object System.Security.AccessControl.RegistrySecurity
                $restoredAcl.SetSecurityDescriptorSddlForm($originalSddl)
                Set-Acl -Path $keyPath -AclObject $restoredAcl -ErrorAction Stop
            } catch {
                Write-Styled -Type Error -Message "FALLO CRÍTICO al restaurar permisos en '$keyPath'. Se requiere intervención manual."
                $state.ManualActions.Add("FALLO CRÍTICO: No se pudo restaurar ACL en '$keyPath'. SDDL original: $originalSddl")
            }
        }
    }
    return $success
}

function Apply-RegistryWithExplorerRestart {
    param([PSCustomObject]$Tweak)
    Write-Styled -Message "Aplicando ajuste para '$($Tweak.description)'..." -NoNewline
    $details = $Tweak.details
    $success = $false
    $errorMessage = "Error no especificado durante la operación."

    try {
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        if (-not (Test-Path $details.path)) { New-Item -Path $details.path -Force | Out-Null }
        New-ItemProperty -Path $details.path -Name $details.name -Value $details.value -PropertyType $details.valueType -Force -ErrorAction Stop
        $success = $true
    } catch {
        # El error se captura aquí principalmente para asegurar que explorer.exe se reinicie siempre.
        # El fallo se registrará en el bloque de abajo.
        $errorMessage = $_.Exception.Message
    } finally {
        Start-Process explorer.exe | Out-Null
    }

    if ($success) {
        Write-Host " [ÉXITO]" -F $Global:Theme.Success
    } else {
        Write-Host " [FALLO]" -F $Global:Theme.Error
        Write-Styled -Type Log -Message "Error al aplicar '$($Tweak.id)': $errorMessage"
    }
    return $success
}

function Apply-Tweak {
    param([PSCustomObject]$Tweak)
    Write-Styled -Message "Aplicando ajuste para '$($Tweak.description)'..." -NoNewline
    $success = $false
    
    try {
        switch ($Tweak.type) {
            'Registry' {
                if (-not (Test-Path $Tweak.details.path)) { New-Item -Path $Tweak.details.path -Force | Out-Null }
                New-ItemProperty -Path $Tweak.details.path -Name $Tweak.details.name -Value $Tweak.details.value -PropertyType $Tweak.details.valueType -Force -ErrorAction Stop
            }
            'AppxPackage' {
                if ($Tweak.details.state -eq 'Removed') {
                    $package = Get-AppxPackage -Name $Tweak.details.packageName -ErrorAction SilentlyContinue
                    if ($package) {
                        $package | Remove-AppxPackage -ErrorAction Stop
                    }
                }
            }
            'PowerPlan' { powercfg.exe /setactive $Tweak.details.schemeGuid }
            'Service' { Set-Service -Name $Tweak.details.name -StartupType $Tweak.details.startupType -ErrorAction Stop }
            'PowerShellCommand' { Invoke-Expression -Command "$($Tweak.details.command) $($Tweak.details.arguments)" }
        }
        $success = $true
        Write-Host " [ÉXITO]" -F $Global:Theme.Success
    } catch {
        Write-Host " [FALLO]" -F $Global:Theme.Error
        Write-Styled -Type Log -Message "Error al aplicar '$($Tweak.id)': $($_.Exception.Message)"
    }
    
    return $success
}

function Invoke-Phase3_Tweaks {
    param([PSCustomObject]$state, [string]$CatalogPath)

    if ($state.FatalErrorOccurred) { return $state }
    if (-not (Test-Path $CatalogPath)) {
        Write-Styled -Type Error -Message "No se encontró el catálogo de tweaks en '$CatalogPath'."
        $state.FatalErrorOccurred = $true
        return $state
    }

    $tweaks = (Get-Content -Raw -Path $CatalogPath -Encoding UTF8 | ConvertFrom-Json).items
    $needsReboot = $false
    $exitMenu = $false

    while (-not $exitMenu) {
        Show-Header -Title "FASE 3: Optimización del Sistema"

        $tweakStatusList = foreach ($tweak in $tweaks) {
            $status = switch ($tweak.type) {
                'Registry'                  { Verify-RegistryTweak -Tweak $tweak }
                'ProtectedRegistry'         { Verify-RegistryTweak -Tweak $tweak }
                'RegistryWithExplorerRestart' { Verify-RegistryTweak -Tweak $tweak }
                'AppxPackage'               { Verify-AppxPackage -Tweak $tweak }
                'PowerPlan'                 { Verify-PowerPlanTweak -Tweak $tweak }
                'Service'                   { Verify-ServiceTweak -Tweak $tweak }
                'PowerShellCommand'         { Verify-PowerShellCommandTweak -Tweak $tweak }
                default                     { "Error" }
            }
            [PSCustomObject]@{ Tweak = $tweak; Status = $status }
        }

        foreach ($item in $tweakStatusList.Select((@('Tweak','Status')),(@{$i=1},{$i++}))) {
            $statusString = "[{0}]" -f $item.Status.ToUpper()
            Write-Styled -Type Step -Message "[$($i)] $($item.Tweak.description) $statusString"
        }

        Write-Host; Write-Styled -Type Consent -Message "[A] Aplicar TODOS los pendientes"; Write-Styled -Type Consent -Message "[0] Volver al Menú Principal"; Write-Host
        
        $numericChoices = 1..$tweakStatusList.Count
        $validChoices = @($numericChoices) + @('A', '0')
        $choice = Invoke-MenuPrompt -ValidChoices $validChoices

        $tweaksToProcess = @()
        switch ($choice) {
            'A' {
                $tweaksToProcess = $tweakStatusList | Where-Object { $_.Status -eq 'Pendiente' }
                if ($tweaksToProcess.Count -eq 0) { Write-Styled -Type Warn -Message "No hay ajustes pendientes."; Start-Sleep -Seconds 2; continue }
            }
            '0' { $exitMenu = $true; continue }
            default {
                $selectedItem = $tweakStatusList[[int]$choice - 1]
                if ($selectedItem.Status -ne 'Pendiente') { Write-Styled -Type Warn -Message "Este ajuste no está pendiente."; Start-Sleep -Seconds 2; continue }
                $tweaksToProcess = @($selectedItem)
            }
        }

        foreach ($item in $tweaksToProcess) {
            $tweak = $item.Tweak
            $applyFunction = switch ($tweak.type) {
                'ProtectedRegistry'         { ${function:Apply-ProtectedRegistryTweak} }
                'RegistryWithExplorerRestart' { ${function:Apply-RegistryWithExplorerRestart} }
                default                     { ${function:Apply-Tweak} }
            }

            $success = & $applyFunction -Tweak $tweak
            if ($success) {
                if ($tweak.type -ne 'PowerPlan') { $needsReboot = $true } # Marcar para la recomendación de reinicio
            } else {
                $state.FatalErrorOccurred = $true
                break
            }
        }

        if ($state.FatalErrorOccurred) {
            $exitMenu = $true
        } elseif ($tweaksToProcess.Count -gt 0) {
            Pause-And-Return
        }
    }

    if (-not $state.FatalErrorOccurred) {
        $state.TweaksApplied = $true
        if ($needsReboot) {
            $state.ManualActions.Add("Se han aplicado ajustes del sistema. Se recomienda reiniciar el equipo para que todos los cambios surtan efecto.")
        }
    }
    return $state
}