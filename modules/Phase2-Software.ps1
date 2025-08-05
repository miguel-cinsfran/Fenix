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

function Invoke-SoftwareManagerUI {
    param(
        [string]$Manager,
        [string]$CatalogFile,
        [PSCustomObject]$state
    )

    try {
        $catalogPackages = (Get-Content -Raw -Path $CatalogFile -Encoding UTF8 | ConvertFrom-Json).items
    } catch {
        Write-Styled -Type Error -Message "Fallo CRÍTICO al procesar '$CatalogFile': $($_.Exception.Message)"
        $state.FatalErrorOccurred = $true
        Pause-And-Return
        return
    }

    $exitManagerUI = $false
    while (-not $exitManagerUI) {
        Show-Header -Title "FASE 2: Administrador de Paquetes ($Manager)"

        $packageStatusList = _Get-PackageStatus -Manager $Manager -CatalogPackages $catalogPackages
        if ($null -eq $packageStatusList) { return } # Salir si la obtención de estado falla

        Write-Styled -Type Title -Message "Estado de paquetes del catálogo:"
        $packageStatusList | Format-Table -Property DisplayName, Status, VersionInfo -AutoSize

        # --- Menú Dinámico ---
        $menuOptions = @{}
        if (($packageStatusList | Where-Object { $_.Status -eq 'No Instalado' }).Count -gt 0) {
            $menuOptions['I'] = "Instalar TODOS los paquetes pendientes"
        }
        if (($packageStatusList | Where-Object { $_.IsUpgradable }).Count -gt 0) {
            $menuOptions['A'] = "Actualizar TODOS los paquetes desactualizados"
        }
        if (($packageStatusList | Where-Object { $_.Status -ne 'No Instalado' }).Count -gt 0) {
            $menuOptions['D'] = "Desinstalar un paquete específico del catálogo"
        }
        $menuOptions['R'] = "Refrescar estado de los paquetes"
        $menuOptions['0'] = "Volver al Menú Principal"

        Write-Styled -Type Title -Message "Acciones Disponibles:"
        foreach ($key in $menuOptions.Keys | Sort-Object) {
            Write-Styled -Type Consent -Message "[$key] $($menuOptions[$key])"
        }

        $choice = Invoke-MenuPrompt -ValidChoices ($menuOptions.Keys | ForEach-Object { "$_" })

        # --- Lógica de Acciones ---
        switch ($choice) {
            'I' {
                $packagesToProcess = $packageStatusList | Where-Object { $_.Status -eq 'No Instalado' }
                foreach ($item in $packagesToProcess) {
                    if ($state.FatalErrorOccurred) { Write-Styled -Type Error -Message "Abortando..."; break }
                    $pkg = $item.Package
                    if ($Manager -eq 'Chocolatey') {
                        $chocoArgs = @("install", $pkg.installId, "-y", "--no-progress")
                        if ($pkg.special_params) { $chocoArgs += "--params='$($pkg.special_params)'" }
                        Execute-InstallJob -PackageName $item.DisplayName -Executable "choco" -ArgumentList ($chocoArgs -join ' ') -state $state -FailureStrings "not found", "was not found"
                    } else { # Winget
                        $wingetArgs = @("install", "--id", $pkg.installId, "--silent", "--accept-package-agreements", "--accept-source-agreements")
                        if ($pkg.source) { $wingetArgs += "--source", $pkg.source }
                        Execute-InstallJob -PackageName $item.DisplayName -Executable "winget" -ArgumentList ($wingetArgs -join ' ') -state $state -FailureStrings "No package found"
                    }
                }
            }
            'A' {
                $packagesToProcess = $packageStatusList | Where-Object { $_.IsUpgradable }
                foreach ($item in $packagesToProcess) {
                    if ($state.FatalErrorOccurred) { Write-Styled -Type Error -Message "Abortando..."; break }
                    $pkg = $item.Package
                    if ($Manager -eq 'Chocolatey') {
                        $chocoArgs = @("upgrade", $pkg.installId, "-y", "--no-progress")
                        Execute-InstallJob -PackageName $item.DisplayName -Executable "choco" -ArgumentList ($chocoArgs -join ' ') -state $state -FailureStrings "not found", "was not found"
                    } else { # Winget
                        $wingetArgs = @("install", "--id", $pkg.installId, "--silent", "--accept-package-agreements", "--accept-source-agreements")
                        Execute-InstallJob -PackageName $item.DisplayName -Executable "winget" -ArgumentList ($wingetArgs -join ' ') -state $state -FailureStrings "No package found"
                    }
                }
            }
            'D' {
                $installedPackages = $packageStatusList | Where-Object { $_.Status -ne 'No Instalado' }
                for ($i = 0; $i -lt $installedPackages.Count; $i++) {
                    Write-Styled -Type Step -Message "[$($i+1)] $($installedPackages[$i].DisplayName)"
                }
                $uninstallChoice = Invoke-MenuPrompt -ValidChoices (1..$installedPackages.Count)
                if ($uninstallChoice) {
                    $item = $installedPackages[[int]$uninstallChoice - 1]
                    $pkg = $item.Package
                    if ((Read-Host "¿Está seguro que desea desinstalar $($item.DisplayName)? (S/N)").Trim().ToUpper() -eq 'S') {
                        if ($Manager -eq 'Chocolatey') {
                            $chocoArgs = @("uninstall", $pkg.installId, "-y")
                            Execute-InstallJob -PackageName $item.DisplayName -Executable "choco" -ArgumentList ($chocoArgs -join ' ') -state $state -FailureStrings "not found", "was not found"
                        } else { # Winget
                            $wingetArgs = @("uninstall", "--id", $pkg.installId, "--silent")
                            Execute-InstallJob -PackageName $item.DisplayName -Executable "winget" -ArgumentList ($wingetArgs -join ' ') -state $state -FailureStrings "No package found"
                        }
                    }
                }
            }
            'R' { continue }
            '0' { $exitManagerUI = $true }
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