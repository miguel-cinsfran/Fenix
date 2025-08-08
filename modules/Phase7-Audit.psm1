<#
.SYNOPSIS
    MÃ³dulo de Fase 7 para la auditorÃ­a y exportaciÃ³n del estado del sistema.
.DESCRIPTION
    Genera un informe en formato Markdown que resume el software instalado
    y los ajustes (tweaks) aplicados por el motor FÃ©nix. TambiÃ©n incluye una
    herramienta de auditorÃ­a de seguridad del cÃ³digo fuente del propio script.
.NOTES
    VersiÃ³n: 1.1
    Autor: miguel-cinsfran
#>

#region System State Audit

function Get-AppliedSystemTweak {
    $tweaksCatalogPath = Join-Path $PSScriptRoot "..\\assets\\catalogs\\system_tweaks.json"
    if (-not (Test-Path $tweaksCatalogPath)) { return @() }

    $tweaks = (Get-Content -Raw -Path $tweaksCatalogPath -Encoding UTF8 | ConvertFrom-Json).items
    $appliedTweaks = [System.Collections.Generic.List[object]]::new()

    foreach ($tweak in $tweaks) {
        $isApplied = $false
        try {
            switch ($tweak.type) {
                "Registry" {
                    $currentValue = Get-ItemPropertyValue -Path $tweak.details.path -Name $tweak.details.name -ErrorAction Stop
                    if ("$currentValue" -eq "$($tweak.details.value)") { $isApplied = $true }
                }
                "ProtectedRegistry" {
                    $currentValue = Get-ItemPropertyValue -Path $tweak.details.path -Name $tweak.details.name -ErrorAction Stop
                    if ("$currentValue" -eq "$($tweak.details.value)") { $isApplied = $true }
                }
                "RegistryWithExplorerRestart" {
                    $currentValue = Get-ItemPropertyValue -Path $tweak.details.path -Name $tweak.details.name -ErrorAction Stop
                    if ("$currentValue" -eq "$($tweak.details.value)") { $isApplied = $true }
                }
                "AppxPackage" {
                    if ($tweak.details.state -eq 'Removed' -and (-not (Get-AppxPackage -Name $tweak.details.packageName -ErrorAction SilentlyContinue))) {
                        $isApplied = $true
                    }
                }
                "PowerPlan" {
                    if ((powercfg.exe /getactivescheme) -match $tweak.details.schemeGuid) { $isApplied = $true }
                }
                "Service" {
                    if ((Get-Service -Name $tweak.details.name -ErrorAction Stop).StartType -eq $tweak.details.startupType) { $isApplied = $true }
                }
                "PowerShellCommand" {
                    if ($tweak.id -eq "DisableHibernation" -and (powercfg.exe /a) -match "La hibernaciÃ³n no estÃ¡ disponible.") {
                        $isApplied = $true
                    }
                }
            }
        } catch {
            # Si Get-ItemPropertyValue falla, el valor no estÃ¡ establecido, por lo tanto el tweak no estÃ¡ aplicado.
        }

        if ($isApplied) {
            $appliedTweaks.Add($tweak)
        }
    }
    return $appliedTweaks
}

function Invoke-SystemStateAudit {
    Show-PhoenixHeader -Title "AuditorÃ­a de Estado del Sistema"
    Write-PhoenixStyledOutput -Type Info -Message "Esta fase generarÃ¡ un informe del estado actual del sistema."

    try {
        $report = [System.Text.StringBuilder]::new()
        $reportName = "System-State-Report-$((Get-Date).ToString('yyyyMMdd-HHmmss')).md"
        $logsPath = Join-Path $PSScriptRoot "..\\logs"
        if (-not (Test-Path $logsPath)) { New-Item -Path $logsPath -ItemType Directory | Out-Null }
        $reportPath = Join-Path $logsPath $reportName

        # --- Cabecera del Informe ---
        [void]$report.AppendLine("# Informe de AuditorÃ­a del Sistema - FÃ©nix")
        [void]$report.AppendLine("Generado el: $(Get-Date)")
        [void]$report.AppendLine("---")

        # --- RecolecciÃ³n de Software Instalado ---
        [void]$report.AppendLine("## Software Instalado")

        # Chocolatey
        Write-PhoenixStyledOutput -Type SubStep -Message "Recolectando paquetes de Chocolatey..."
        $chocoPackages = & choco list --limit-output --local-only 2>$null | ForEach-Object { $parts = $_ -split '\|'; if ($parts.Length -eq 2) { [PSCustomObject]@{ Name = $parts[0]; Version = $parts[1] } } }
        [void]$report.AppendLine("### Chocolatey")
        if ($chocoPackages) {
            [void]$report.AppendLine("| Paquete | VersiÃ³n |")
            [void]$report.AppendLine("|---|---|")
            $chocoPackages | ForEach-Object { [void]$report.AppendLine("| $($_.Name) | $($_.Version) |") }
        } else {
            [void]$report.AppendLine("No se encontraron paquetes de Chocolatey.")
        }
        [void]$report.AppendLine()

        # Winget
        Write-PhoenixStyledOutput -Type SubStep -Message "Recolectando paquetes de Winget..."
        $wingetOutput = & winget list 2>$null
        # Simple parsing, as winget's format is tricky. This is good enough for an audit.
        $wingetPackages = $wingetOutput | Select-Object -Skip 2 | ForEach-Object {
            $line = $_.Trim()
            if ($line) {
                $parts = $line -split '\s{2,}'
                if ($parts.Count -ge 2) { [PSCustomObject]@{ Name = $parts[0..($parts.Count-2)] -join ' '; Version = $parts[-1] } }
            }
        }
        [void]$report.AppendLine("### Winget")
        if ($wingetPackages) {
            [void]$report.AppendLine("| Paquete | VersiÃ³n |")
            [void]$report.AppendLine("|---|---|")
            $wingetPackages | ForEach-Object { [void]$report.AppendLine("| $($_.Name) | $($_.Version) |") }
        } else {
            [void]$report.AppendLine("No se encontraron paquetes de Winget.")
        }
        [void]$report.AppendLine()

        # --- RecolecciÃ³n de Ajustes Aplicados (Tweaks) ---
        Write-PhoenixStyledOutput -Type SubStep -Message "Recolectando ajustes del sistema aplicados..."
        $appliedTweaks = Get-AppliedSystemTweak
        [void]$report.AppendLine("## Ajustes del Sistema Aplicados")
        if ($appliedTweaks.Count -gt 0) {
            [void]$report.AppendLine("| DescripciÃ³n del Ajuste |")
            [void]$report.AppendLine("|---|")
            $appliedTweaks | ForEach-Object { [void]$report.AppendLine("| $($_.description) |") }
        } else {
            [void]$report.AppendLine("No se encontraron ajustes aplicados.")
        }
        [void]$report.AppendLine()

        # --- Guardar el Informe ---
        Out-File -FilePath $reportPath -InputObject $report.ToString() -Encoding utf8
        Write-PhoenixStyledOutput -Type Success -Message "Informe de auditorÃ­a guardado en: $reportPath"

    } catch {
        Write-PhoenixStyledOutput -Type Error -Message "OcurriÃ³ un error al generar el informe de auditorÃ­a: $($_.Exception.Message)"
    }
}

#endregion

#region Code Security Audit

function Invoke-CodeSecurityAudit {
    Show-PhoenixHeader -Title "AuditorÃ­a de Seguridad del CÃ³digo"
    Write-PhoenixStyledOutput -Type Info -Message "Buscando el uso de comandos potencialmente sensibles en el cÃ³digo fuente de FÃ©nix..."
    Write-Host

    $commandsToAudit = @(
        "Invoke-RegistryActionWithPrivileges",
        "Invoke-NativeCommandWithOutputCapture",
        "Restart-Computer",
        "Stop-Computer",
        "Set-ExecutionPolicy",
        "Invoke-Expression",
        "iex"
    )

    $projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    $scriptFiles = Get-ChildItem -Path $projectRoot -Recurse -Include @("*.ps1", "*.psm1")

    $totalFindings = 0

    foreach ($command in $commandsToAudit) {
        $foundInFiles = @{}
        foreach ($file in $scriptFiles) {
            $matches = Select-String -Path $file.FullName -Pattern $command -SimpleMatch -CaseSensitive
            if ($matches) {
                $foundInFiles[$file.FullName] = $matches.Count
                $totalFindings += $matches.Count
            }
        }

        if ($foundInFiles.Count -gt 0) {
            Write-PhoenixStyledOutput -Type Warn -Message "Comando encontrado: '$command'"
            $foundInFiles.GetEnumerator() | ForEach-Object {
                $relativePath = $_.Name.Replace($projectRoot, "").TrimStart('\')
                Write-PhoenixStyledOutput -Type SubStep -Message "-> $relativePath (Ocurrencias: $($_.Value))"
            }
            Write-Host
        }
    }

    if ($totalFindings -eq 0) {
        Write-PhoenixStyledOutput -Type Success -Message "AuditorÃ­a completada. No se encontraron comandos de riesgo en el cÃ³digo fuente."
    } else {
        Write-PhoenixStyledOutput -Type Success -Message "AuditorÃ­a completada. Total de hallazgos: $totalFindings"
    }
}

#endregion

function Invoke-AuditPhase {
    [CmdletBinding()]
    param()

    $exitSubMenu = $false
    while (-not $exitSubMenu) {
        Show-PhoenixHeader -Title "FASE 7: AuditorÃ­a"
        Write-PhoenixStyledOutput -Type Step -Message "[1] Generar Informe de Estado del Sistema"
        Write-PhoenixStyledOutput -Type Step -Message "[2] Ejecutar AuditorÃ­a de Seguridad del CÃ³digo Fuente"
        Write-PhoenixStyledOutput -Type Step -Message "[0] Volver al MenÃº Principal"
        Write-Host

        $choice = Request-MenuSelection -ValidChoices @('1', '2', '0') -AllowMultipleSelections:$false
        if ([string]::IsNullOrEmpty($choice)) { continue }

        switch ($choice) {
            '1' {
                Invoke-SystemStateAudit
                Request-Continuation -Message "Presione Enter para volver al menÃº de auditorÃ­a..."
            }
            '2' {
                Invoke-CodeSecurityAudit
                Request-Continuation -Message "Presione Enter para volver al menÃº de auditorÃ­a..."
            }
            '0' { $exitSubMenu = $true }
        }
    }
}

Export-ModuleMember -Function Invoke-AuditPhase
