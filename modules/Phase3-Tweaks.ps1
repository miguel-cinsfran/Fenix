<#
.SYNOPSIS
    Módulo de Fase 3 para la aplicación de optimizaciones y configuraciones del sistema.
.DESCRIPTION
    Presenta un menú interactivo de "tweaks" del sistema, con verificación de estado
    precisa y manejo de errores robusto (en teoría), incluyendo manipulación de ACL para claves protegidas.
.NOTES
    Versión: 5.0
    Autor: miguel-cinsfran
#>

# --- FUNCIONES DE VERIFICACIÓN PRECISA (VERIFY) ---
function Verify-RegistryTweak {
    param([PSCustomObject]$Tweak)
    $details = $Tweak.details
    try {
        $regKeyObject = Get-ItemProperty -Path $details.path -ErrorAction Stop
    } catch {
        # Si Get-ItemProperty falla, la ruta o la propiedad no existen.
        # Para cualquier Tweak que busque establecer un valor, este estado es 'Pendiente'.
        # Esto corrige el bug donde LeftAlignTaskbar se marcaba como 'Aplicado' incorrectamente.
        return "Pendiente"
    }

    # Esta parte se mantiene igual para manejar correctamente el caso especial de FullContextMenu.
    $currentValue = if ($regKeyObject.PSObject.Properties.Name -contains $details.name) { $regKeyObject.$($details.name) } else { $null }
    if ($Tweak.id -eq "FullContextMenu") {
        # Este Tweak se considera aplicado si el valor (Default) está presente y vacío.
        if ($null -ne $currentValue -and $currentValue -eq "") { return "Aplicado" }
        return "Pendiente"
    }

    # Comparación estándar para todos los demás tweaks del registro.
    if ("$currentValue" -eq "$($details.value)") { return "Aplicado" }
    return "Pendiente"
}

function Verify-AppxPackage {
    param([PSCustomObject]$Tweak)
    $package = Get-AppxPackage -Name $Tweak.details.packageName -ErrorAction SilentlyContinue
    if ($Tweak.details.state -eq 'Removed') {
        if ($null -eq $package) { return "Aplicado" }
        return "Pendiente"
    }
    # Se puede extender para estados 'Presente' si es necesario en el futuro
    return "Error"
}

function Verify-PowerPlanTweak {
    param([PSCustomObject]$Tweak)
    if ((powercfg.exe /getactivescheme) -match $Tweak.details.schemeGuid) { return "Aplicado" }
    return "Pendiente"
}
function Verify-ServiceTweak {
    param([PSCustomObject]$Tweak)
    try {
        $service = Get-CimInstance -ClassName Win32_Service -Filter "Name = '$($Tweak.details.name)'"
        if ($service.StartMode -eq $Tweak.details.startupType) { return "Aplicado" }
        return "Pendiente"
    } catch { return "NoEncontrado" }
}
function Verify-PowerShellCommandTweak {
    param([PSCustomObject]$Tweak)
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
                Write-Styled -Type Warn -Message "ACCIÓN MANUAL REQUERIDA: Restaurar permisos para la clave del Registro: $keyPath"
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
    $details = $Tweak.details
    $success = $false
    
    try {
        switch ($Tweak.type) {
            'Registry' {
                if (-not (Test-Path $details.path)) { New-Item -Path $details.path -Force | Out-Null }
                New-ItemProperty -Path $details.path -Name $details.name -Value $details.value -PropertyType $details.valueType -Force -ErrorAction Stop
            }
            'AppxPackage' {
                if ($details.state -eq 'Removed') {
                    $package = Get-AppxPackage -Name $details.packageName -ErrorAction SilentlyContinue
                    if ($package) {
                        $package | Remove-AppxPackage -ErrorAction Stop
                    }
                }
            }
            'PowerPlan' { powercfg.exe /setactive $details.schemeGuid }
            'Service' { Set-Service -Name $details.name -StartupType $details.startupType -ErrorAction Stop }
            'PowerShellCommand' { Invoke-Expression -Command "$($details.command) $($details.arguments)" }
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
    param([string]$CatalogPath)
    if (-not (Test-Path $CatalogPath)) {
        Write-Styled -Type Error -Message "No se encontró el catálogo de tweaks en '$CatalogPath'."
        Pause-And-Return
        return
    }
    $tweaks = (Get-Content -Raw -Path $CatalogPath -Encoding UTF8 | ConvertFrom-Json).items

    $exitMenu = $false
    while (-not $exitMenu) {
        Show-Header -Title "FASE 3: Optimización del Sistema"
        $tweakStatusList = @()
        foreach ($tweak in $tweaks) {
            $status = "Error"
            switch ($tweak.type) {
                'Registry' { $status = Verify-RegistryTweak -Tweak $tweak }
                'ProtectedRegistry' { $status = Verify-RegistryTweak -Tweak $tweak }
                'AppxPackage' { $status = Verify-AppxPackage -Tweak $tweak }
                'RegistryWithExplorerRestart' { $status = Verify-RegistryTweak -Tweak $tweak }
                'PowerPlan' { $status = Verify-PowerPlanTweak -Tweak $tweak }
                'Service' { $status = Verify-ServiceTweak -Tweak $tweak }
                'PowerShellCommand' { $status = Verify-PowerShellCommandTweak -Tweak $tweak }
            }
            $tweakStatusList += [PSCustomObject]@{ Tweak = $tweak; Status = $status }
        }

        for ($i = 0; $i -lt $tweakStatusList.Count; $i++) {
            $item = $tweakStatusList[$i]
            $statusString = "[{0}]" -f $item.Status.ToUpper()
            $statusColor = if ($item.Status -eq 'Aplicado') { $Theme.Success } else { $Theme.Warn }
            Write-Host ("[{0,2}] {1,-50} {2}" -f ($i+1), $item.Tweak.description, $statusString) -ForegroundColor $statusColor
        }
        Write-Host
        Write-Styled -Type Consent -Message "-> Escriba un NÚMERO para aplicar un ajuste individual."
        Write-Styled -Type Consent -Message "-> [A] Aplicar TODOS los pendientes."
        Write-Styled -Type Consent -Message "-> [R] Refrescar la lista."
        Write-Styled -Type Consent -Message "-> [0] Volver al Menú Principal."
        
        $numericChoices = 1..$tweakStatusList.Count
        $validChoices = @($numericChoices) + @('A', 'R', '0')
        $choice = Invoke-MenuPrompt -ValidChoices $validChoices -PromptMessage "Seleccione una opción"

        $errorOccurred = $false
        switch ($choice) {
            'A' {
                $pendingTweaks = $tweakStatusList | Where-Object { $_.Status -eq 'Pendiente' }
                if ($pendingTweaks.Count -eq 0) { Write-Styled -Type Warn -Message "No hay ajustes pendientes."; Start-Sleep -Seconds 2; continue }

                foreach ($item in $pendingTweaks) {
                    $tweakToApply = $item.Tweak
                    $applyFunction = switch ($tweakToApply.type) {
                        'ProtectedRegistry' { ${function:Apply-ProtectedRegistryTweak} }
                        'RegistryWithExplorerRestart' { ${function:Apply-RegistryWithExplorerRestart} }
                        default { ${function:Apply-Tweak} }
                    }
                    if (-not (& $applyFunction -Tweak $tweakToApply)) { $errorOccurred = $true; break }
                }
            }
            'R' { continue }
            '0' { $exitMenu = $true; continue }
            default {
                $selectedItem = $tweakStatusList[[int]$choice - 1]
                if ($selectedItem.Status -ne 'Pendiente') { Write-Styled -Type Warn -Message "Este ajuste no está pendiente."; Start-Sleep -Seconds 2; continue }

                $tweakToApply = $selectedItem.Tweak
                $applyFunction = switch ($tweakToApply.type) {
                    'ProtectedRegistry' { ${function:Apply-ProtectedRegistryTweak} }
                    'RegistryWithExplorerRestart' { ${function:Apply-RegistryWithExplorerRestart} }
                    default { ${function:Apply-Tweak} }
                }
                if (-not (& $applyFunction -Tweak $tweakToApply)) { $errorOccurred = $true }
            }
        }
        if ($errorOccurred) {
            Write-Styled -Type Error -Message "Ocurrió un error al aplicar un ajuste. No se continuará."
            Pause-And-Return
            continue
        }
        Pause-And-Return
    }
}