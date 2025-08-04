<#
.SYNOPSIS
    Módulo de Fase 3 para la aplicación de optimizaciones y configuraciones del sistema.
.DESCRIPTION
    Presenta un menú interactivo de "tweaks" del sistema, con verificación de estado
    precisa y manejo de errores robusto (en teoría), incluyendo manipulación de ACL para claves protegidas.
.NOTES
    Versión: 3.1 (Me re costo)
    Autor: miguel-cinsfran
#>

# --- FUNCIONES DE VERIFICACIÓN PRECISA (VERIFY) ---
function Verify-RegistryTweak {
    param([PSCustomObject]$Tweak)
    $details = $Tweak.details
    try {
        $regKeyObject = Get-ItemProperty -Path $details.path -ErrorAction Stop
    } catch {
        if ($Tweak.id -eq "LeftAlignTaskbar" -and $details.value -eq 0) { return "Aplicado" }
        if ($Tweak.id -eq "FullContextMenu") { return "Pendiente" }
        return "Pendiente"
    }
    $currentValue = if ($regKeyObject.PSObject.Properties.Name -contains $details.name) { $regKeyObject.$($details.name) } else { $null }
    if ($Tweak.id -eq "FullContextMenu") {
        if ($null -ne $currentValue -and $currentValue -eq "") { return "Aplicado" }
        return "Pendiente"
    }
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
    $originalOwnerSid = $null
    
    try {
        if (-not (Test-Path $keyPath)) {
            New-Item -Path $keyPath -Force | Out-Null
        }
        $acl = Get-Acl $keyPath
        $ownerAccount = New-Object System.Security.Principal.NTAccount($acl.Owner)
        $originalOwnerSid = $ownerAccount.Translate([System.Security.Principal.SecurityIdentifier])
        $administratorsSid = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
        $acl.SetOwner($administratorsSid)
        $rule = New-Object System.Security.AccessControl.RegistryAccessRule($administratorsSid, "FullControl", "Allow")
        $acl.SetAccessRule($rule)
        Set-Acl -Path $keyPath -AclObject $acl -ErrorAction Stop
        New-ItemProperty -Path $details.path -Name $details.name -Value $details.value -PropertyType $details.valueType -Force -ErrorAction Stop
        $success = $true
        Write-Host " [ÉXITO]" -F $Global:Theme.Success
    } catch {
        Write-Host " [FALLO]" -F $Global:Theme.Error
        Write-Styled -Type Log -Message "Error al aplicar '$($Tweak.id)': $($_.Exception.Message)"
    } finally {
        if ($originalOwnerSid) {
            try {
                $acl = Get-Acl $keyPath
                $acl.SetOwner($originalOwnerSid)
                $rule = New-Object System.Security.AccessControl.RegistryAccessRule($administratorsSid, "FullControl", "Allow")
                $acl.RemoveAccessRule($rule)
                Set-Acl -Path $keyPath -AclObject $acl -ErrorAction Stop
            } catch {
                Write-Styled -Type Error -Message "FALLO CRÍTICO al restaurar permisos en '$keyPath'. Se requiere intervención manual."
                $state.ManualActions.Add("FALLO CRÍTICO al restaurar permisos en '$keyPath'. Propietario original SID: $($originalOwnerSid.Value)")
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
    
    try {
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        if (-not (Test-Path $details.path)) { New-Item -Path $details.path -Force | Out-Null }
        New-ItemProperty -Path $details.path -Name $details.name -Value $details.value -PropertyType $details.valueType -Force -ErrorAction Stop
        $success = $true
    } catch {
    } finally {
        Start-Process explorer.exe
    }

    if ($success) {
        Write-Host " [ÉXITO]" -F $Global:Theme.Success
    } else {
        Write-Host " [FALLO]" -F $Global:Theme.Error
        Write-Styled -Type Log -Message "Error al aplicar '$($Tweak.id)': $($_.Exception.Message)"
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
                New-ItemProperty -Path $Tweak.details.path -Name $details.name -Value $details.value -PropertyType $details.valueType -Force -ErrorAction Stop
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
    if (-not (Test-Path $CatalogPath)) { Write-Styled -Type Error -Message "No se encontró el catálogo de tweaks en '$CatalogPath'."; $state.FatalErrorOccurred = $true; return $state }
    $tweaks = (Get-Content -Raw -Path $CatalogPath -Encoding UTF8 | ConvertFrom-Json).items
    $anyTweakApplied = $false
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
            Write-Styled -Type Step -Message "[$($i+1)] $($item.Tweak.description) $statusString"
        }
        Write-Host; Write-Styled -Type Consent -Message "[A] Aplicar TODOS los pendientes"; Write-Styled -Type Consent -Message "[0] Volver al Menú Principal"; Write-Host
        
        $numericChoices = 1..$tweakStatusList.Count
        $validChoices = @($numericChoices) + @('A', '0')
        $choice = Invoke-MenuPrompt -ValidChoices $validChoices

        $actionTaken = $false
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
                    if (-not (& $applyFunction -Tweak $tweakToApply)) { $state.FatalErrorOccurred = $true; break }
                    $anyTweakApplied = $true
                }
                $actionTaken = $true
            }
            '0' { $exitMenu = $true }
            default {
                $selectedItem = $tweakStatusList[[int]$choice - 1]
                if ($selectedItem.Status -ne 'Pendiente') { Write-Styled -Type Warn -Message "Este ajuste no está pendiente."; Start-Sleep -Seconds 2; continue }
                $tweakToApply = $selectedItem.Tweak
                $applyFunction = switch ($tweakToApply.type) {
                    'ProtectedRegistry' { ${function:Apply-ProtectedRegistryTweak} }
                    'RegistryWithExplorerRestart' { ${function:Apply-RegistryWithExplorerRestart} }
                    default { ${function:Apply-Tweak} }
                }
                if ((& $applyFunction -Tweak $tweakToApply)) { $anyTweakApplied = $true } else { $state.FatalErrorOccurred = $true }
                $actionTaken = $true
            }
        }
        if ($actionTaken -and -not $state.FatalErrorOccurred) {
            Pause-And-Return
            if ($tweaks | Where-Object { $_.type -eq 'AppxPackage' -and $_.id -eq $tweakToApply.id }) {
                $state.ManualActions.Add("Se ha eliminado un paquete de aplicación. Se recomienda reiniciar el equipo.")
            }
        }
        if ($state.FatalErrorOccurred) { $exitMenu = $true }
    }
    if (-not $state.FatalErrorOccurred) {
        $state.TweaksApplied = $true
        if ($anyTweakApplied -and -not ($tweaks | Where-Object { $_.type -eq 'AppxPackage' })) { 
            $state.ManualActions.Add("Se han aplicado ajustes del sistema. Se recomienda reiniciar el equipo.") 
        }
    }
    return $state
}