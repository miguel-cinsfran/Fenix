<#
.SYNOPSIS
    Módulo de Fase 7 para la auditoría y exportación del estado del sistema.
.DESCRIPTION
    Genera un informe en formato Markdown que resume el software instalado
    y los ajustes (tweaks) aplicados por el motor Fénix.
.NOTES
    Versión: 1.0
    Autor: miguel-cinsfran
#>

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
                    if ($tweak.id -eq "DisableHibernation" -and (powercfg.exe /a) -match "La hibernación no está disponible.") {
                        $isApplied = $true
                    }
                }
            }
        } catch {
            # Si Get-ItemPropertyValue falla, el valor no está establecido, por lo tanto el tweak no está aplicado.
        }

        if ($isApplied) {
            $appliedTweaks.Add($tweak)
        }
    }
    return $appliedTweaks
}

function Invoke-AuditPhase {
    [CmdletBinding()]
    param()

    Show-PhoenixHeader -Title "FASE 7: Auditoría y Exportación"
    Write-PhoenixStyledOutput -Type Info -Message "Esta fase generará un informe del estado actual del sistema."

    try {
        $report = [System.Text.StringBuilder]::new()
        $reportName = "Audit-Report-$((Get-Date).ToString('yyyyMMdd-HHmmss')).md"
        $reportPath = Join-Path $PSScriptRoot "..\\logs\\$reportName"

        # --- Cabecera del Informe ---
        $report.AppendLine("# Informe de Auditoría del Sistema - Fénix")
        $report.AppendLine("Generado el: $(Get-Date)")
        $report.AppendLine("---")

        # --- Recolección de Software Instalado ---
        $report.AppendLine("## Software Instalado")

        # Chocolatey
        Write-PhoenixStyledOutput -Type SubStep -Message "Recolectando paquetes de Chocolatey..."
        $chocoPackages = & choco list --limit-output --local-only 2>$null | ForEach-Object { $parts = $_ -split '\|'; if ($parts.Length -eq 2) { [PSCustomObject]@{ Name = $parts[0]; Version = $parts[1] } } }
        $report.AppendLine("### Chocolatey")
        if ($chocoPackages) {
            $report.AppendLine("| Paquete | Versión |")
            $report.AppendLine("|---|---|")
            $chocoPackages | ForEach-Object { $report.AppendLine("| $($_.Name) | $($_.Version) |") }
        } else {
            $report.AppendLine("No se encontraron paquetes de Chocolatey.")
        }
        $report.AppendLine()

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
        $report.AppendLine("### Winget")
        if ($wingetPackages) {
            $report.AppendLine("| Paquete | Versión |")
            $report.AppendLine("|---|---|")
            $wingetPackages | ForEach-Object { $report.AppendLine("| $($_.Name) | $($_.Version) |") }
        } else {
            $report.AppendLine("No se encontraron paquetes de Winget.")
        }
        $report.AppendLine()

        # --- Recolección de Ajustes Aplicados (Tweaks) ---
        Write-PhoenixStyledOutput -Type SubStep -Message "Recolectando ajustes del sistema aplicados..."
        $appliedTweaks = Get-AppliedSystemTweak
        $report.AppendLine("## Ajustes del Sistema Aplicados")
        if ($appliedTweaks.Count -gt 0) {
            $report.AppendLine("| Descripción del Ajuste |")
            $report.AppendLine("|---|")
            $appliedTweaks | ForEach-Object { $report.AppendLine("| $($_.description) |") }
        } else {
            $report.AppendLine("No se encontraron ajustes aplicados.")
        }
        $report.AppendLine()

        # --- Guardar el Informe ---
        Out-File -FilePath $reportPath -InputObject $report.ToString() -Encoding utf8
        Write-PhoenixStyledOutput -Type Success -Message "Informe de auditoría guardado en: $reportPath"

    } catch {
        Write-PhoenixStyledOutput -Type Error -Message "Ocurrió un error al generar el informe de auditoría: $($_.Exception.Message)"
    }

    Request-Continuation
}

# Exportar únicamente las funciones destinadas al consumo público para evitar la
# exposición de helpers internos y cumplir con las mejores prácticas de modularización.
Export-ModuleMember -Function Invoke-AuditPhase
