<#
.SYNOPSIS
    Módulo de Fase 2 para la instalación de software desde manifiestos.
.DESCRIPTION
    Contiene la lógica para cargar catálogos de Chocolatey y Winget, y presenta
    un submenú para permitir la instalación granular o completa de los paquetes.
.NOTES
    Versión: 1.0
    Autor: miguel-cinsfran
#>

function Execute-InstallJob {
    param(
        [string]$PackageName,
        [string]$Executable,
        [string]$ArgumentList,
        [PSCustomObject]$state,
        [string[]]$FailureStrings
    )

    # Deshabilitar el timeout de inactividad para instalaciones de software,
    # ya que pueden tener largos periodos de descarga sin actividad en la consola.
    $result = Invoke-NativeCommand -Executable $Executable -ArgumentList $ArgumentList -FailureStrings $FailureStrings -Activity "Instalando $PackageName" -IdleTimeoutEnabled $false

    if (-not $result.Success) {
        $state.FatalErrorOccurred = $true
        Write-Styled -Type Error -Message "Falló la instalación de $PackageName."
        if ($result.Output) {
            Write-Styled -Type Log -Message "--- INICIO DE SALIDA DEL PROCESO ---"
            $result.Output | ForEach-Object { Write-Styled -Type Log -Message $_ }
            Write-Styled -Type Log -Message "--- FIN DE SALIDA DEL PROCESO ---"
        }
    } else {
        Write-Styled -Type Success -Message "Instalación de $PackageName finalizada."
    }
}

function _Get-PackageStatus {
    param(
        [string]$Manager,
        [array]$CatalogPackages
    )

    Write-Styled -Type Info -Message "Obteniendo estado de los paquetes para $Manager..."
    $installedPackages = @{}
    $outdatedPackages = @{}

    if ($Manager -eq 'Chocolatey') {
        $listResult = Invoke-NativeCommand -Executable "choco" -ArgumentList "list --limit-output --local-only" -Activity "Consultando paquetes de Chocolatey"
        if ($listResult.Success) {
            $listResult.Output -split "`n" | ForEach-Object { $id, $version = $_ -split '\|'; if ($id) { $installedPackages[$id.Trim()] = $version.Trim() } }
        } else { Write-Styled -Type Error -Message "No se pudo obtener la lista de paquetes instalados."; return $null }

        $outdatedResult = Invoke-NativeCommand -Executable "choco" -ArgumentList "outdated --limit-output" -Activity "Buscando actualizaciones de Chocolatey"
        if ($outdatedResult.Success) {
            $outdatedResult.Output -split "`n" | ForEach-Object { $id, $current, $available, $pinned = $_ -split '\|'; if ($id) { $outdatedPackages[$id.Trim()] = @{ Current = $current.Trim(); Available = $available.Trim() } } }
        } # No es un error fatal si esto falla, podría no haber ninguno desactualizado.

    } else { # Winget
        $listResult = Invoke-NativeCommand -Executable "winget" -ArgumentList "list --disable-interactivity --accept-source-agreements" -Activity "Consultando paquetes de Winget"
        if (-not $listResult.Success) { Write-Styled -Type Error -Message "No se pudo obtener la lista de paquetes instalados."; return $null }

        $upgradeResult = Invoke-NativeCommand -Executable "winget" -ArgumentList "upgrade --disable-interactivity --accept-source-agreements --include-unknown" -Activity "Buscando actualizaciones de Winget"

        $installedLines = $listResult.Output -split "`n"
        $upgradeLines = if ($upgradeResult.Success) { $upgradeResult.Output -split "`n" } else { @() }

        foreach ($pkg in $CatalogPackages) {
            $checkId = if ($pkg.checkName) { $pkg.checkName } else { $pkg.installId }
            $regexId = [regex]::Escape($checkId)

            foreach ($line in $installedLines) {
                if ($line -match "^(.+?)\s+($regexId)\s+") {
                    # Winget usa múltiples espacios, es mejor un split para la versión
                    $version = ($line -split '\s+')[-2]
                    $installedPackages[$pkg.installId] = $version
                    break
                }
            }
            foreach ($line in $upgradeLines) {
                if ($line -match "^(.+?)\s+($regexId)\s+") {
                    $parts = $line -split '\s+'
                    $outdatedPackages[$pkg.installId] = @{ Current = $parts[-3]; Available = $parts[-2] }
                    break
                }
            }
        }
    }

    foreach ($pkg in $CatalogPackages) {
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
            Execute-InstallJob -PackageName $item.DisplayName -Executable "choco" -ArgumentList ($chocoArgs -join ' ') -state $state -FailureStrings "not found", "was not found"
        }
        elseif ($Manager -eq 'Winget') {
            # Winget usa 'install' tanto para instalar como para actualizar.
            $wingetArgs = @("install", "--id", $pkg.installId, "--silent", "--disable-interactivity", "--accept-package-agreements", "--accept-source-agreements")
            if ($pkg.source) { $wingetArgs += "--source", $pkg.source }
            Execute-InstallJob -PackageName $item.DisplayName -Executable "winget" -ArgumentList ($wingetArgs -join ' ') -state $state -FailureStrings "No package found"
        }
    }

    if ($packagesToProcess.Count -gt 0 -and -not $state.FatalErrorOccurred) {
        Pause-And-Return
    }
}

function _Show-InstalledPackages {
    param([array]$Packages)
    Write-Styled -Type SubStep -Message "Lista de paquetes del catálogo y su estado:"
    $installed = $Packages | Where-Object { $_.Status -ne 'No Instalado' }
    if ($installed.Count -eq 0) {
        Write-Styled -Type Warn -Message "No hay paquetes instalados de este catálogo."
    } else {
        $installed | Format-Table -Property DisplayName, Status, VersionInfo -AutoSize
    }
    Pause-And-Return
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
        Write-Styled -Type Step -Message "[3] Listar paquetes instalados del catálogo"
        Write-Styled -Type Step -Message "[0] Volver al menú anterior"
        Write-Host
        $mainChoice = Invoke-MenuPrompt -ValidChoices @('1', '2', '3', '0') -PromptMessage "Seleccione una acción"

        if ($mainChoice -eq '0') { $exitManagerUI = $true; continue }

        $packageStatusList = _Get-PackageStatus -Manager $Manager -CatalogPackages $catalogPackages
        if ($null -eq $packageStatusList) { continue }

        switch ($mainChoice) {
            '1' {
                $uninstalledPackages = $packageStatusList | Where-Object { $_.Status -eq 'No Instalado' }
                _Handle-SoftwareAction -Action "Install" -Manager $Manager -PackagesToAction $uninstalledPackages -state $state
            }
            '2' {
                $upgradablePackages = $packageStatusList | Where-Object { $_.IsUpgradable }
                _Handle-SoftwareAction -Action "Upgrade" -Manager $Manager -PackagesToAction $upgradablePackages -state $state
            }
            '3' {
                _Show-InstalledPackages -Packages $packageStatusList
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