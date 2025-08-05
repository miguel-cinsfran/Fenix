<#
.SYNOPSIS
    Módulo de Fase 2 para la instalación de software desde manifiestos.
.DESCRIPTION
    Contiene la lógica para cargar catálogos de Chocolatey y Winget, y presenta
    un submenú para permitir la instalación granular o completa de los paquetes.
.NOTES
    Versión: 2.0
    Autor: miguel-cinsfran
#>

function _Execute-SoftwareJob {
    param(
        [string]$PackageName,
        [string]$Executable,
        [string]$ArgumentList,
        [PSCustomObject]$state,
        [string[]]$FailureStrings
    )

    # Deshabilitar el timeout de inactividad para instalaciones de software,
    # ya que pueden tener largos periodos de descarga sin actividad en la consola.
    $result = Invoke-NativeCommand -Executable $Executable -ArgumentList $ArgumentList -FailureStrings $FailureStrings -Activity "Ejecutando: $($Executable) $($ArgumentList)" -IdleTimeoutEnabled $false

    if (-not $result.Success) {
        $state.FatalErrorOccurred = $true
        Write-Styled -Type Error -Message "Falló la operación para ${PackageName}."
        if ($result.Output) {
            Write-Styled -Type Log -Message "--- INICIO DE SALIDA DEL PROCESO ---"
            $result.Output | ForEach-Object { Write-Styled -Type Log -Message $_ }
            Write-Styled -Type Log -Message "--- FIN DE SALIDA DEL PROCESO ---"
        }
    } else {
        Write-Styled -Type Success -Message "Operación para ${PackageName} finalizada."
    }
}

function _Get-ChocolateyPackageStatus {
    param([array]$CatalogPackages)

    $packageStatusList = @()
    for ($i = 0; $i -lt $CatalogPackages.Count; $i++) {
        $pkg = $CatalogPackages[$i]
        $installId = $pkg.installId
        $displayName = if ($pkg.name) { $pkg.name } else { $installId }

        Write-Progress -Activity "Consultando estado de paquetes de Chocolatey" -Status "Verificando: ${displayName}" -PercentComplete (($i / $CatalogPackages.Count) * 100)

        $status = "No Instalado"
        $versionInfo = ""
        $isUpgradable = $false
        $currentVersion = ""

        # Comprobar si el paquete está instalado usando la salida más robusta
        $listResult = Invoke-NativeCommand -Executable "choco" -ArgumentList "list --exact --regular-output ""${installId}""" -Activity "Consultando si ${displayName} está instalado"

        if ($listResult.Success -and $listResult.Output) {
            # Salida esperada: package|version
            $parts = $listResult.Output.Trim() -split '\|'
            if ($parts.Count -ge 2) {
                $currentVersion = $parts[1]
                $status = "Instalado"
                $versionInfo = "(v${currentVersion})"
            }
        }

        # Si está instalado, comprobar si hay actualizaciones
        if ($status -eq "Instalado") {
            $outdatedResult = Invoke-NativeCommand -Executable "choco" -ArgumentList "outdated --exact --regular-output ""${installId}""" -Activity "Buscando actualización para ${displayName}"

            if ($outdatedResult.Success -and $outdatedResult.Output) {
                # Salida esperada: package|current_version|available_version|pinned
                $parts = $outdatedResult.Output.Trim() -split '\|'
                if ($parts.Count -ge 3) {
                    $availableVersion = $parts[2]
                    $status = "Actualización Disponible"
                    $versionInfo = "(v${currentVersion} -> v${availableVersion})"
                    $isUpgradable = $true
                }
            }
        }

        $packageStatusList += [PSCustomObject]@{
            DisplayName  = $displayName
            Package      = $pkg
            Status       = $status
            VersionInfo  = $versionInfo
            IsUpgradable = $isUpgradable
        }
    }
    Write-Progress -Activity "Consultando estado de paquetes de Chocolatey" -Completed
    return $packageStatusList
}

function _Get-WingetPackageStatus {
    param([array]$CatalogPackages)

    # Fallback to CLI parsing if the module isn't available or fails to import
    if ($Global:UseWingetCli -or -not (Get-Module -ListAvailable -Name Microsoft.WinGet.Client)) {
        Write-Styled -Type Warn -Message "Usando método de reserva para Winget. La información puede ser menos precisa."
        return _Get-WingetPackageStatus_Cli -CatalogPackages $CatalogPackages
    }

    try {
        Import-Module Microsoft.WinGet.Client -ErrorAction Stop
    } catch {
        Write-Styled -Type Error -Message "No se pudo importar el módulo 'Microsoft.WinGet.Client'."
        Write-Styled -Type Warn -Message "Cambiando a método de reserva para Winget."
        return _Get-WingetPackageStatus_Cli -CatalogPackages $CatalogPackages
    }

    $packageStatusList = @()
    for ($i = 0; $i -lt $CatalogPackages.Count; $i++) {
        $pkg = $CatalogPackages[$i]
        $installId = $pkg.installId
        $displayName = if ($pkg.name) { $pkg.name } else { $installId }

        Write-Progress -Activity "Consultando estado de paquetes Winget (Módulo)" -Status "Verificando: ${displayName}" -PercentComplete (($i / $CatalogPackages.Count) * 100)

        $status = "No Instalado"
        $versionInfo = ""
        $isUpgradable = $false

        try {
            # Usar un ID de verificación alternativo si se proporciona
            $checkId = if ($pkg.checkName) { $pkg.checkName } else { $installId }
            $wingetPackage = Get-WinGetPackage -Id $checkId -ErrorAction Stop
        } catch {
            # Get-WinGetPackage throws an exception if the package is not found
            $wingetPackage = $null
        }

        if ($null -ne $wingetPackage) {
            if ($wingetPackage.InstalledVersion) {
                $status = "Instalado"
                $versionInfo = "(v$($wingetPackage.InstalledVersion))"

                # Check for updates by comparing versions
                if ($wingetPackage.AvailableVersion -and ($wingetPackage.InstalledVersion -ne $wingetPackage.AvailableVersion)) {
                    $status = "Actualización Disponible"
                    $versionInfo = "(v$($wingetPackage.InstalledVersion) -> v$($wingetPackage.AvailableVersion))"
                    $isUpgradable = $true
                }
            }
        }

        $packageStatusList += [PSCustomObject]@{
            DisplayName  = $displayName
            Package      = $pkg
            Status       = $status
            VersionInfo  = $versionInfo
            IsUpgradable = $isUpgradable
        }
    }
    Write-Progress -Activity "Consultando estado de paquetes Winget (Módulo)" -Completed
    return $packageStatusList
}

# Fallback function using the old CLI parsing method
function _Get-WingetPackageStatus_Cli {
    param([array]$CatalogPackages)

    $packageStatusList = @()
    foreach ($pkg in $CatalogPackages) {
        $installId = $pkg.installId
        $displayName = if ($pkg.name) { $pkg.name } else { $pkg.installId }

        Write-Progress -Activity "Consultando estado de paquetes Winget (CLI)" -Status "Verificando: ${displayName}"

        $checkId = if ($pkg.checkName) { $pkg.checkName } else { $installId }

        $status = "No Instalado"
        $versionInfo = ""
        $isUpgradable = $false
        $currentVersion = ""

        $listResult = Invoke-NativeCommand -Executable "winget" -ArgumentList "list --id ""${checkId}"" --accept-source-agreements --disable-interactivity" -Activity "Consultando si ${displayName} está instalado"

        if ($listResult.Output -match $checkId) {
            $outputLines = $listResult.Output -split "`n" | Where-Object { $_ -match $checkId }
            if ($outputLines.Count -gt 0) {
                $parts = $outputLines[0] -split '\s{2,}' | Where-Object { $_ }
                if ($parts.Count -ge 3) {
                    $currentVersion = $parts[2].Trim()
                    $status = "Instalado"
                    $versionInfo = "(v${currentVersion})"
                }
            }
        }

        if ($status -eq "Instalado") {
            $upgradeResult = Invoke-NativeCommand -Executable "winget" -ArgumentList "upgrade --id ""${checkId}"" --accept-source-agreements --disable-interactivity --include-unknown" -Activity "Buscando actualización para ${displayName}"
            if ($upgradeResult.Success -and $upgradeResult.Output -match $checkId) {
                $outputLines = $upgradeResult.Output -split "`n" | Where-Object { $_ -match $checkId }
                if ($outputLines.Count -gt 0) {
                    $parts = $outputLines[0] -split '\s{2,}' | Where-Object { $_ }
                    if ($parts.Count -ge 4) {
                        $availableVersion = $parts[3].Trim()
                        $status = "Actualización Disponible"
                        $versionInfo = "(v${currentVersion} -> v${availableVersion})"
                        $isUpgradable = $true
                    }
                }
            }
        }

        $packageStatusList += [PSCustomObject]@{
            DisplayName  = $displayName
            Package      = $pkg
            Status       = $status
            VersionInfo  = $versionInfo
            IsUpgradable = $isUpgradable
        }
    }
    Write-Progress -Activity "Consultando estado de paquetes Winget (CLI)" -Completed
    return $packageStatusList
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
        Write-Styled -Type Error -Message "Fallo CRÍTICO al procesar '${CatalogFile}': $($_.Exception.Message)"
        $state.FatalErrorOccurred = $true
        Pause-And-Return
        return
    }

    $exitManagerUI = $false
    while (-not $exitManagerUI) {
        Show-Header -Title "FASE 2: Administrador de Paquetes (${Manager})" -NoClear

        Write-Styled -Type Info -Message "Obteniendo estado de los paquetes para ${Manager}..."
        $packageStatusList = if ($Manager -eq 'Chocolatey') {
            _Get-ChocolateyPackageStatus -CatalogPackages $catalogPackages
        } else {
            _Get-WingetPackageStatus -CatalogPackages $catalogPackages
        }

        if ($null -eq $packageStatusList) {
            Write-Styled -Type Error -Message "No se pudo continuar debido a un error al obtener el estado de los paquetes."
            Pause-And-Return
            return
        }

        Write-Styled -Type Title -Message "Estado de paquetes del catálogo:"
        if ($packageStatusList.Count -eq 0) {
            Write-Styled -Type Warn -Message "El catálogo de software está vacío."
        } else {
            # Usar un bucle para un formato personalizado más claro y con colores.
            for ($i = 0; $i -lt $packageStatusList.Count; $i++) {
                $item = $packageStatusList[$i]

                # Determinar el color y el prefijo basado en el estado del paquete
                $statusColor = $Theme.Subtle # Color por defecto para 'No Instalado'
                $statusIcon = "[ ]"
                if ($item.IsUpgradable) {
                    $statusColor = $Theme.Warn # Amarillo para actualizaciones
                    $statusIcon = "[↑]"
                } elseif ($item.Status -eq 'Instalado') {
                    $statusColor = $Theme.Success # Verde para instalado y actualizado
                    $statusIcon = "[✓]"
                }

                # Construir la cadena de texto final
                # Ejemplo: [✓] 1. 7-Zip                  - Instalado (v23.01)
                #          [↑] 2. Google Chrome          - Actualización Disponible (v120 -> v121)
                #          [ ] 3. Visual Studio Code     - No Instalado
                $displayText = $item.DisplayName
                $statusText = "$($item.Status) $($item.VersionInfo)".Trim()
                $line = "{0,-4} {1,2}. {2,-25} - {3}" -f $statusIcon, ($i + 1), $displayText, $statusText

                Write-Host $line -ForegroundColor $statusColor
            }
        }

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

        switch ($choice) {
            'I' {
                $packagesToProcess = $packageStatusList | Where-Object { $_.Status -eq 'No Instalado' }
                foreach ($item in $packagesToProcess) {
                    if ($state.FatalErrorOccurred) { Write-Styled -Type Error -Message "Abortando..."; break }
                    $pkg = $item.Package
                    if ($Manager -eq 'Chocolatey') {
                        $chocoArgs = @("install", $pkg.installId, "-y", "--no-progress")
                        if ($pkg.special_params) { $chocoArgs += "--params='$($pkg.special_params)'" }
                        _Execute-SoftwareJob -PackageName $item.DisplayName -Executable "choco" -ArgumentList ($chocoArgs -join ' ') -state $state -FailureStrings "not found", "was not found"
                    } else { # Winget
                        $wingetArgs = @("install", "--id", $pkg.installId, "--silent", "--accept-package-agreements", "--accept-source-agreements")
                        if ($pkg.source) { $wingetArgs += "--source", $pkg.source }
                        _Execute-SoftwareJob -PackageName $item.DisplayName -Executable "winget" -ArgumentList ($wingetArgs -join ' ') -state $state -FailureStrings "No package found"
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
                        _Execute-SoftwareJob -PackageName $item.DisplayName -Executable "choco" -ArgumentList ($chocoArgs -join ' ') -state $state -FailureStrings "not found", "was not found"
                    } else { # Winget
                        $wingetArgs = @("install", "--id", $pkg.installId, "--silent", "--accept-package-agreements", "--accept-source-agreements")
                        _Execute-SoftwareJob -PackageName $item.DisplayName -Executable "winget" -ArgumentList ($wingetArgs -join ' ') -state $state -FailureStrings "No package found"
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
                            _Execute-SoftwareJob -PackageName $item.DisplayName -Executable "choco" -ArgumentList ($chocoArgs -join ' ') -state $state -FailureStrings "not found", "was not found"
                        } else { # Winget
                            $wingetArgs = @("uninstall", "--id", $pkg.installId, "--silent")
                            _Execute-SoftwareJob -PackageName $item.DisplayName -Executable "winget" -ArgumentList ($wingetArgs -join ' ') -state $state -FailureStrings "No package found"
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
        Write-Styled -Type Error -Message "No se encontraron los archivos de catálogo en '${CatalogPath}'."
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