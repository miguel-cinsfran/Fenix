<#
.SYNOPSIS
    Módulo de Fase 2 para la instalación de software desde manifiestos.
.DESCRIPTION
    Contiene la lógica para cargar catálogos de Chocolatey y Winget, y presenta
    una interfaz de usuario interactiva para listar, instalar y actualizar paquetes.
.NOTES
    Versión: 2.1
    Autor: miguel-cinsfran
#>

# Mantener la función original de ejecución de trabajos, como se prefiera.
function Execute-InstallJob {
    param(
        [string]$PackageName, 
        [scriptblock]$InstallBlock, 
        [PSCustomObject]$state,
        [string]$Manager
    )

    $job = Start-Job -ScriptBlock $InstallBlock
    Write-Styled -Type Info -Message "Iniciando instalación de $PackageName..."
    while ($job.State -eq 'Running') {
        Write-Progress -Activity "Instalando $PackageName" -Status "Ejecutando en segundo plano..." -PercentComplete -1
        Start-Sleep -Milliseconds 500
    }
    Write-Progress -Activity "Instalando $PackageName" -Completed
    
    try {
        $jobOutput = Receive-Job $job
        $jobFailed = $false
        $failureReason = ""

        if ($job.State -ne 'Completed') {
            $jobFailed = $true
            $failureReason = "El estado del trabajo fue '$($job.State)'."
        } else {
            if ($Manager -eq 'Chocolatey') {
                if ($jobOutput -match "not found|was not found") { $jobFailed = $true; $failureReason = "Chocolatey no pudo encontrar el paquete." }
            }
            elseif ($Manager -eq 'Winget') {
                if ($jobOutput -match "No se encontró ningún paquete|No package found") { $jobFailed = $true; $failureReason = "Winget no pudo encontrar el paquete." }
            }
        }

        if ($jobFailed) {
            $state.FatalErrorOccurred = $true
            Write-Styled -Type Error -Message "Falló la instalación de $PackageName. Razón: $failureReason"
        } else {
            Write-Styled -Type Success -Message "Instalación de $PackageName finalizada."
        }
    } finally {
        Remove-Job $job -Force
    }
}

function _Get-PackageStatus {
    param(
        [string]$Manager,
        [array]$CatalogPackages
    )

    Write-Styled -Type Info -Message "Obteniendo estado de los paquetes... (Esto puede tardar hasta 2 minutos por comando)"

    $installedPackages = @{}
    $outdatedPackages = @{}

    if ($Manager -eq 'Chocolatey') {
        $listResult = Invoke-JobWithTimeout -ScriptBlock { choco list --limit-output --local-only } -Activity "Consultando paquetes de Chocolatey"
        if ($listResult.Success) {
            $listResult.Output | ForEach-Object { $id, $version = $_ -split '\|'; if ($id) { $installedPackages[$id.Trim()] = $version.Trim() } }
        } else { Write-Styled -Type Error -Message "Timeout: No se pudo obtener la lista de paquetes instalados."; return $null }

        $outdatedResult = Invoke-JobWithTimeout -ScriptBlock { choco outdated --limit-output } -Activity "Buscando actualizaciones de Chocolatey"
        if ($outdatedResult.Success) {
            $outdatedResult.Output | ForEach-Object { $id, $current, $available, $pinned = $_ -split '\|'; if ($id) { $outdatedPackages[$id.Trim()] = @{ Current = $current.Trim(); Available = $available.Trim() } } }
        } else { Write-Styled -Type Error -Message "Timeout: No se pudo obtener la lista de paquetes desactualizados."; return $null }

    } else { # Winget
        # La lógica de Winget es más compleja y se mantiene directa por ahora.
        $installedOutput = winget list --disable-interactivity --accept-source-agreements
        $upgradeOutput = winget upgrade --disable-interactivity --accept-source-agreements --include-unknown

        foreach ($pkg in $CatalogPackages) {
            $regexId = [regex]::Escape($pkg.installId)
            foreach ($line in $installedOutput) {
                if ($line -match "^(.+?)\s+($regexId)\s+([^\s]+)") {
                    $installedPackages[$pkg.installId] = $matches[3]
                    break
                }
            }
            foreach ($line in $upgradeOutput) {
                if ($line -match "^(.+?)\s+($regexId)\s+([^\s]+)\s+([^\s]+)") {
                    $outdatedPackages[$pkg.installId] = @{ Current = $matches[3]; Available = $matches[4] }
                    break
                }
            }
        }
    }

    return foreach ($pkg in $CatalogPackages) {
        $installId = $pkg.installId
        $status = "No Instalado"
        $versionInfo = ""
        $isUpgradable = $false

        if ($outdatedPackages.ContainsKey($installId)) {
            $status = "Actualización Disponible"
            $versionInfo = "(v$($outdatedPackages[$installId].Current) -> v$($outdatedPackages[$installId].Available))"
            $isUpgradable = $true
        } elseif ($installedPackages.ContainsKey($installId)) {
            $status = "Instalado"
            $versionInfo = "(v$($installedPackages[$installId]))"
        }

        [PSCustomObject]@{
            DisplayName  = if ($pkg.name) { $pkg.name } else { $pkg.installId }
            Package      = $pkg
            Status       = $status
            VersionInfo  = $versionInfo
            IsUpgradable = $isUpgradable
        }
    }
}

function _Handle-SoftwareAction {
    param(
        [string]$Action,
        [string]$Manager,
        [array]$PackagesToAction,
        [PSCustomObject]$state
    )

    if ($PackagesToAction.Count -eq 0) {
        Write-Styled -Type Warn -Message "No hay paquetes que requieran esta acción."
        Start-Sleep -Seconds 2
        return
    }

    $actionVerb = switch ($Action) {
        "Install" { "instalar" }
        "Upgrade" { "actualizar" }
    }

    for ($i = 0; $i -lt $PackagesToAction.Count; $i++) {
        $item = $PackagesToAction[$i]
        Write-Host ("[{0,2}] {1,-35} {2}" -f ($i + 1), $item.DisplayName, $item.VersionInfo)
    }
    Write-Host
    Write-Styled -Type Consent -Message "[A] $($actionVerb.ToUpper()) TODOS los paquetes listados"
    Write-Styled -Type Consent -Message "[0] Volver"
    Write-Host

    $numericChoices = 1..$PackagesToAction.Count
    $validChoices = @($numericChoices) + @('A', '0')
    $choice = Invoke-MenuPrompt -ValidChoices $validChoices -PromptMessage "Seleccione un paquete para $($actionVerb), (A) para todos, o (0) para volver"

    if ($choice -eq '0') { return }

    $packagesToProcess = if ($choice -eq 'A') { $PackagesToAction } else { @($PackagesToAction[[int]$choice - 1]) }

    foreach ($item in $packagesToProcess) {
        if ($state.FatalErrorOccurred) { Write-Styled -Type Error -Message "Abortando debido a error previo."; break }

        $pkg = $item.Package
        $command = if ($Action -eq 'Upgrade') { "upgrade" } else { "install" }

        if ($Manager -eq 'Chocolatey') {
            $chocoArgs = @($command, $pkg.installId, "-y", "--no-progress")
            if ($pkg.PSObject.Properties.Name -contains 'special_params') { $chocoArgs += "--params='$($pkg.special_params)'" }
            Execute-InstallJob -PackageName $item.DisplayName -InstallBlock { & choco $using:chocoArgs } -state $state -Manager 'Chocolatey'
        }
        elseif ($Manager -eq 'Winget') {
            # Winget usa 'install' tanto para instalar como para actualizar.
            $wingetArgs = @("install", "--id", $pkg.installId, "--silent", "--disable-interactivity", "--accept-package-agreements", "--accept-source-agreements")
            if ($pkg.source) { $wingetArgs += "--source", $pkg.source }
            Execute-InstallJob -PackageName $item.DisplayName -InstallBlock { & winget $using:wingetArgs } -state $state -Manager 'Winget'
        }
    }

    if ($packagesToProcess.Count -gt 0 -and -not $state.FatalErrorOccurred) {
        Pause-And-Return
    }
}

function Invoke-SoftwareManagerUI {
    param(
        [string]$Manager,
        [string]$CatalogFile,
        [PSCustomObject]$state
    )

    try {
        $catalogPackages = (Get-Content -Raw -Path $CatalogFile -Encoding UTF8 | ConvertFrom-Json).items
    } catch {
        Write-Styled -Type Error -Message "Fallo CRÍTICO al procesar '$CatalogFile'."
        Write-Styled -Type Log -Message "Error técnico original: $($_.Exception.Message)"
        $state.FatalErrorOccurred = $true
        Pause-And-Return
        return
    }

    $exitManagerUI = $false
    while (-not $exitManagerUI) {
        Show-Header -Title "FASE 2: Administrador de Paquetes ($Manager)"
        Write-Styled -Type Step -Message "[1] Instalar paquetes del catálogo"
        Write-Styled -Type Step -Message "[2] Actualizar paquetes instalados"
        Write-Styled -Type Step -Message "[0] Volver al menú anterior"
        Write-Host
        $mainChoice = Invoke-MenuPrompt -ValidChoices @('1', '2', '0') -PromptMessage "Seleccione una acción"

        if ($mainChoice -eq '0') { $exitManagerUI = $true; continue }

        $packageStatusList = _Get-PackageStatus -Manager $Manager -CatalogPackages $catalogPackages
        if ($null -eq $packageStatusList) { continue } # Si la obtención de estado falló, volver al menú

        switch ($mainChoice) {
            '1' {
                $uninstalledPackages = $packageStatusList | Where-Object { $_.Status -eq 'No Instalado' }
                _Handle-SoftwareAction -Action "Install" -Manager $Manager -PackagesToAction $uninstalledPackages -state $state
            }
            '2' {
                $upgradablePackages = $packageStatusList | Where-Object { $_.IsUpgradable }
                _Handle-SoftwareAction -Action "Upgrade" -Manager $Manager -PackagesToAction $upgradablePackages -state $state
            }
        }
    }
}

function Invoke-Phase2_SoftwareMenu {
    param([PSCustomObject]$state, [string]$CatalogPath)
    if ($state.FatalErrorOccurred) { return $state }
    
    $chocoCatalog = Join-Path $CatalogPath "chocolatey_catalog.json"
    $wingetCatalog = Join-Path $CatalogPath "winget_catalog.json"
    if (-not (Test-Path $chocoCatalog) -or -not (Test-Path $wingetCatalog)) {
        Write-Styled -Type Error -Message "No se encontraron los archivos de catálogo en '$CatalogPath'."
        $state.FatalErrorOccurred = $true
        return $state
    }

    $exitSubMenu = $false
    while (-not $exitSubMenu) {
        Show-Header -Title "FASE 2: Instalación de Software"
        Write-Styled -Type Step -Message "[1] Administrar paquetes de Chocolatey"
        Write-Styled -Type Step -Message "[2] Administrar paquetes de Winget"
        Write-Styled -Type Step -Message "[0] Volver al Menú Principal"
        Write-Host

        $choice = Invoke-MenuPrompt -ValidChoices @('1', '2', '0') -PromptMessage "Seleccione una opción"

        switch ($choice) {
            '1' {
                Invoke-SoftwareManagerUI -Manager 'Chocolatey' -CatalogFile $chocoCatalog -state $state
            }
            '2' {
                Invoke-SoftwareManagerUI -Manager 'Winget' -CatalogFile $wingetCatalog -state $state
            }
            '0' {
                $exitSubMenu = $true
            }
        }
    }

    if (-not $state.FatalErrorOccurred) { $state.SoftwareInstalled = $true }
    return $state
}