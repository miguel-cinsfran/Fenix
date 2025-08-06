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
        [string[]]$FailureStrings
    )

    # Deshabilitar el timeout de inactividad para instalaciones de software,
    # ya que pueden tener largos periodos de descarga sin actividad en la consola.
    $result = Invoke-NativeCommand -Executable $Executable -ArgumentList $ArgumentList -FailureStrings $FailureStrings -Activity "Ejecutando: ${Executable} ${ArgumentList}" -IdleTimeoutEnabled $false

    if (-not $result.Success) {
        Write-Styled -Type Error -Message "Falló la operación para ${PackageName}."
        if ($result.Output) {
            Write-Styled -Type Log -Message "--- INICIO DE SALIDA DEL PROCESO ---"
            $result.Output | ForEach-Object { Write-Styled -Type Log -Message $_ }
            Write-Styled -Type Log -Message "--- FIN DE SALIDA DEL PROCESO ---"
        }
        # Lanzar una excepción permite que el bucle que llama se detenga.
        throw "La operación de software para ${PackageName} falló."
    } else {
        Write-Styled -Type Success -Message "Operación para ${PackageName} finalizada."
    }
}

function _Get-ChocolateyPackageStatus {
    param([array]$CatalogPackages)

    # Paso 1: Obtener todos los paquetes instalados y desactualizados en dos llamadas eficientes.
    Write-Styled -Type Info -Message "Consultando paquetes de Chocolatey instalados..."
    # Se añade '-y' para aceptar automáticamente cualquier licencia o prompt que pueda causar un cuelgue.
    $listResult = Invoke-NativeCommand -Executable "choco" -ArgumentList "list --limit-output -y" -Activity "Consultando paquetes de Chocolatey"
    if (-not $listResult.Success) {
        Write-Styled -Type Error -Message "No se pudo obtener la lista de paquetes instalados con Chocolatey."
        return $null
    }
    $installedPackages = @{}
    $listResult.Output -split "`n" | ForEach-Object {
        $id, $version = $_ -split '\|'; if ($id) { $installedPackages[$id.Trim()] = $version.Trim() }
    }

    Write-Styled -Type Info -Message "Buscando actualizaciones para paquetes de Chocolatey..."
    $outdatedResult = Invoke-NativeCommand -Executable "choco" -ArgumentList "outdated --limit-output -y" -Activity "Buscando actualizaciones de Chocolatey"
    $outdatedPackages = @{}
    if ($outdatedResult.Success) {
        $outdatedResult.Output -split "`n" | ForEach-Object {
            $id, $current, $available, $pinned = $_ -split '\|'; if ($id) { $outdatedPackages[$id.Trim()] = @{ Current = $current.Trim(); Available = $available.Trim() } }
        }
    }

    # Paso 2: Procesar la lista del catálogo contra los resultados obtenidos.
    $packageStatusList = @()
    for ($i = 0; $i -lt $CatalogPackages.Count; $i++) {
        $pkg = $CatalogPackages[$i]
        $installId = $pkg.installId
        $displayName = if ($pkg.name) { $pkg.name } else { $installId }

        Write-Progress -Activity "Procesando estado de paquetes de Chocolatey" -Status "Verificando: ${displayName}" -PercentComplete (($i / $CatalogPackages.Count) * 100)

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

        $packageStatusList += [PSCustomObject]@{
            DisplayName  = $displayName
            Package      = $pkg
            Status       = $status
            VersionInfo  = $versionInfo
            IsUpgradable = $isUpgradable
        }
    }
    Write-Progress -Activity "Procesando estado de paquetes de Chocolatey" -Completed
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

    # --- Optimización de Escalabilidad ---
    # 1. Obtener TODOS los paquetes instalados y disponibles en una sola llamada.
    Write-Styled -Type Info -Message "Consultando todos los paquetes de Winget a través del módulo. Esto puede tardar un momento..."
    try {
        $allPackages = Get-WinGetPackage
        # 2. Crear un mapa (HashTable) para búsqueda instantánea por ID.
        $packageMap = $allPackages | Group-Object -Property Id -AsHashTable -AsString
    } catch {
        Write-Styled -Type Error -Message "Fallo crítico al obtener la lista de paquetes de Winget: $($_.Exception.Message)"
        return $null
    }

    $packageStatusList = @()
    for ($i = 0; $i -lt $CatalogPackages.Count; $i++) {
        $pkg = $CatalogPackages[$i]
        $installId = $pkg.installId
        $displayName = if ($pkg.name) { $pkg.name } else { $installId }
        Write-Progress -Activity "Procesando estado de paquetes Winget" -Status "Verificando: ${displayName}" -PercentComplete (($i / $CatalogPackages.Count) * 100)

        $status = "No Instalado"
        $versionInfo = ""
        $isUpgradable = $false

        # Usar un ID de verificación alternativo si se proporciona
        $checkId = if ($pkg.checkName) { $pkg.checkName } else { $installId }

        # 3. Consultar el mapa en memoria (mucho más rápido).
        if ($packageMap.ContainsKey($checkId)) {
            $wingetPackage = $packageMap[$checkId]
            if ($wingetPackage.InstalledVersion) {
                $status = "Instalado"
                $versionInfo = "(v$($wingetPackage.InstalledVersion))"
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
    Write-Progress -Activity "Procesando estado de paquetes Winget" -Completed
    return $packageStatusList
}

# Fallback function using the old CLI parsing method
function _Get-WingetPackageStatus_Cli {
    param([array]$CatalogPackages)

    Write-Styled -Type Info -Message "Consultando todos los paquetes de Winget (CLI). Esto puede tardar un momento..."

    # --- Optimización de Escalabilidad (CLI) ---
    # 1. Obtener todos los paquetes instalados y actualizables en dos llamadas.
    $listResult = Invoke-NativeCommand -Executable "winget" -ArgumentList "list --accept-source-agreements --disable-interactivity" -Activity "Listando todos los paquetes de Winget"
    $upgradeResult = Invoke-NativeCommand -Executable "winget" -ArgumentList "upgrade --include-unknown --accept-source-agreements --disable-interactivity" -Activity "Buscando todas las actualizaciones de Winget"

    # 2. Parsear la salida a mapas (HashTables) para búsqueda rápida.
    $installedPackages = @{}
    if ($listResult.Success) {
        # Omitir las primeras líneas de encabezado y la línea de guiones
        $listResult.Output -split "`n" | Select-Object -Skip 2 | ForEach-Object {
            $parts = $_ -split '\s{2,}' | Where-Object { $_ }
            if ($parts.Count -ge 3) {
                $id = $parts[1].Trim()
                $version = $parts[2].Trim()
                if ($id) { $installedPackages[$id] = $version }
            }
        }
    }

    $upgradablePackages = @{}
    if ($upgradeResult.Success) {
        $upgradeResult.Output -split "`n" | Select-Object -Skip 2 | ForEach-Object {
            $parts = $_ -split '\s{2,}' | Where-Object { $_ }
            if ($parts.Count -ge 4) {
                $id = $parts[1].Trim()
                $currentVersion = $parts[2].Trim()
                $availableVersion = $parts[3].Trim()
                if ($id) { $upgradablePackages[$id] = @{ Current = $currentVersion; Available = $availableVersion } }
            }
        }
    }

    $packageStatusList = @()
    for ($i = 0; $i -lt $CatalogPackages.Count; $i++) {
        $pkg = $CatalogPackages[$i]
        $installId = $pkg.installId
        $displayName = if ($pkg.name) { $pkg.name } else { $installId }
        Write-Progress -Activity "Procesando estado de paquetes Winget (CLI)" -Status "Verificando: ${displayName}" -PercentComplete (($i / $CatalogPackages.Count) * 100)

        $checkId = if ($pkg.checkName) { $pkg.checkName } else { $installId }
        $status = "No Instalado"
        $versionInfo = ""
        $isUpgradable = $false

        if ($upgradablePackages.ContainsKey($checkId)) {
            $status = "Actualización Disponible"
            $versionInfo = "(v$($upgradablePackages[$checkId].Current) -> v$($upgradablePackages[$checkId].Available))"
            $isUpgradable = $true
        } elseif ($installedPackages.ContainsKey($checkId)) {
            $status = "Instalado"
            $versionInfo = "(v$($installedPackages[$checkId]))"
        }

        $packageStatusList += [PSCustomObject]@{
            DisplayName  = $displayName
            Package      = $pkg
            Status       = $status
            VersionInfo  = $versionInfo
            IsUpgradable = $isUpgradable
        }
    }
    Write-Progress -Activity "Procesando estado de paquetes Winget (CLI)" -Completed
    return $packageStatusList
}

#region Package Action Helpers
function _Install-Package {
    param([string]$Manager, [PSCustomObject]$Item)
    $pkg = $Item.Package
    if ($Manager -eq 'Chocolatey') {
        $chocoArgs = @("install", $pkg.installId, "-y", "--no-progress")
        if ($pkg.special_params) { $chocoArgs += "--params='$($pkg.special_params)'" }
        _Execute-SoftwareJob -PackageName $Item.DisplayName -Executable "choco" -ArgumentList ($chocoArgs -join ' ') -FailureStrings "not found", "was not found"
    } else { # Winget
        $wingetArgs = @("install", "--id", $pkg.installId, "--silent", "--accept-package-agreements", "--accept-source-agreements")
        if ($pkg.source) { $wingetArgs += "--source", $pkg.source }
        _Execute-SoftwareJob -PackageName $Item.DisplayName -Executable "winget" -ArgumentList ($wingetArgs -join ' ') -FailureStrings "No package found"
    }
}

function _Uninstall-Package {
    param([string]$Manager, [PSCustomObject]$Item)
    $pkg = $Item.Package
    if ($Manager -eq 'Chocolatey') {
        $chocoArgs = @("uninstall", $pkg.installId, "-y")
        _Execute-SoftwareJob -PackageName $Item.DisplayName -Executable "choco" -ArgumentList ($chocoArgs -join ' ') -FailureStrings "not found", "was not found"
    } else { # Winget
        $wingetArgs = @("uninstall", "--id", $pkg.installId, "--silent")
        _Execute-SoftwareJob -PackageName $Item.DisplayName -Executable "winget" -ArgumentList ($wingetArgs -join ' ') -FailureStrings "No package found"
    }
}

function _Update-Package {
    param([string]$Manager, [PSCustomObject]$Item)
    $pkg = $Item.Package
    if ($Manager -eq 'Chocolatey') {
        $chocoArgs = @("upgrade", $pkg.installId, "-y", "--no-progress")
        _Execute-SoftwareJob -PackageName $Item.DisplayName -Executable "choco" -ArgumentList ($chocoArgs -join ' ') -FailureStrings "not found", "was not found"
    } else { # Winget
        # Winget upgrade is the same as install
        $wingetArgs = @("install", "--id", $pkg.installId, "--silent", "--accept-package-agreements", "--accept-source-agreements")
        _Execute-SoftwareJob -PackageName $Item.DisplayName -Executable "winget" -ArgumentList ($wingetArgs -join ' ') -FailureStrings "No package found"
    }
}
#endregion

#region Menus
function _Invoke-SinglePackageMenu {
    param(
        [string]$Manager,
        [PSCustomObject]$Item
    )
    $exitMenu = $false
    while (-not $exitMenu) {
        Show-Header -Title "Gestionando: $($Item.DisplayName)" -NoClear
        Write-Styled -Type Info -Message "Estado: $($Item.Status) $($Item.VersionInfo)"

        $menuOptions = @{}
        if ($Item.Status -eq 'No Instalado') {
            $menuOptions['I'] = "Instalar paquete"
        } else {
            if ($Item.IsUpgradable) {
                $menuOptions['A'] = "Actualizar paquete"
            }
            $menuOptions['D'] = "Desinstalar paquete"
        }
        $menuOptions['0'] = "Volver"

        Write-Styled -Type Title -Message "Acciones Disponibles:"
        foreach ($key in $menuOptions.Keys | Sort-Object) {
            Write-Styled -Type Consent -Message "[$key] $($menuOptions[$key])"
        }

        $choice = Invoke-MenuPrompt -ValidChoices ($menuOptions.Keys | ForEach-Object { "$_" })

        switch ($choice) {
            'I' { _Install-Package -Manager $Manager -Item $Item; $exitMenu = $true }
            'A' { _Update-Package -Manager $Manager -Item $Item; $exitMenu = $true }
            'D' {
                if ((Invoke-MenuPrompt -ValidChoices @('S','N') -PromptMessage "Está seguro que desea desinstalar $($Item.DisplayName)?") -eq 'S') {
                    _Uninstall-Package -Manager $Manager -Item $Item
                }
                $exitMenu = $true
            }
            '0' { $exitMenu = $true }
        }
    }
}

function Invoke-SoftwareManagerUI {
    param(
        [string]$Manager,
        [string]$CatalogFile
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

        # Construir y mostrar el menú estandarizado
        $menuItems = $packageStatusList | ForEach-Object {
            [PSCustomObject]@{
                Description = "$($_.DisplayName) $($_.VersionInfo)".Trim()
                Status      = $_.Status
            }
        }
        $actionOptions = [ordered]@{
             'I' = 'Instalar TODOS los paquetes pendientes.'
        }
        if (($packageStatusList | Where-Object { $_.IsUpgradable }).Count -gt 0) {
            $actionOptions['A'] = 'Actualizar TODOS los paquetes desactualizados.'
        }
        $actionOptions['R'] = 'Refrescar la lista de paquetes.'
        $actionOptions['0'] = 'Volver al menú anterior.'

        $choice = Invoke-StandardMenu -Title "FASE 2: Administrador de Paquetes (${Manager})" -MenuItems $menuItems -ActionOptions $actionOptions

        switch ($choice) {
            'I' {
                $packagesToInstall = $packageStatusList | Where-Object { $_.Status -eq 'No Instalado' }
                if ($packagesToInstall.Count -gt 0) {
                    Write-Styled -Type Info -Message "Instalando $($packagesToInstall.Count) paquetes..."
                    try {
                        foreach ($item in $packagesToInstall) { _Install-Package -Manager $Manager -Item $item }
                    } catch {
                        Write-Styled -Type Error -Message "Ocurrió un error durante la instalación masiva."
                        Pause-And-Return
                    }
                } else {
                    Write-Styled -Type Info -Message "No hay paquetes nuevos para instalar."; Start-Sleep -Seconds 2
                }
            }
            'A' {
                $packagesToUpdate = $packageStatusList | Where-Object { $_.IsUpgradable }
                if ($packagesToUpdate.Count -gt 0) {
                    Write-Styled -Type Info -Message "Actualizando $($packagesToUpdate.Count) paquetes..."
                    try {
                        foreach ($item in $packagesToUpdate) { _Update-Package -Manager $Manager -Item $item }
                    } catch {
                        Write-Styled -Type Error -Message "Ocurrió un error durante la actualización masiva."
                        Pause-And-Return
                    }
                } else {
                    Write-Styled -Type Info -Message "No hay paquetes para actualizar."; Start-Sleep -Seconds 2
                }
            }
            'R' { continue }
            '0' { $exitManagerUI = $true }
            default { # Es un número
                $packageIndex = [int]$choice - 1
                $selectedItem = $packageStatusList[$packageIndex]
                _Invoke-SinglePackageMenu -Manager $Manager -Item $selectedItem
            }
        }
    }
}

function Invoke-Phase2_PreFlightChecks {
    Show-Header -Title "FASE 2: Verificación de Dependencias"

    $allChecksPassed = $true

    Write-Styled -Message "Verificando existencia de Chocolatey..." -NoNewline
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Write-Host " [NO ENCONTRADO]" -F $Global:Theme.Warn
        Write-Styled -Type Consent -Message "El gestor de paquetes Chocolatey no está instalado y es requerido para esta fase."
        if ((Invoke-MenuPrompt -ValidChoices @('S','N') -PromptMessage "Desea que el script intente instalarlo ahora?") -eq 'S') {
            Write-Styled -Type Info -Message "Instalando Chocolatey... Esto puede tardar unos minutos."
            try {
                Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
                Write-Styled -Type Success -Message "Chocolatey se ha instalado correctamente."
            } catch {
                Write-Styled -Type Error -Message "La instalación automática de Chocolatey falló."
                $allChecksPassed = $false
            }
        } else {
            $allChecksPassed = $false
        }
    } else {
        Write-Host " [ÉXITO]" -F $Global:Theme.Success
    }

    Write-Styled -Message "Verificando existencia de Winget..." -NoNewline
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host " [NO ENCONTRADO]" -F $Global:Theme.Error
        Write-Styled -Type Error -Message "El gestor de paquetes Winget no fue encontrado. Por favor, actualice su 'App Installer' desde la Microsoft Store."
        $allChecksPassed = $false
    } else {
        Write-Host " [ÉXITO]" -F $Global:Theme.Success
    }

    Write-Styled -Message "Verificando módulo de PowerShell para Winget..." -NoNewline
    if (-not (Get-Module -ListAvailable -Name Microsoft.WinGet.Client)) {
        Write-Host " [NO ENCONTRADO]" -F $Global:Theme.Warn
        Write-Styled -Type Consent -Message "El módulo de PowerShell para Winget es recomendado para una operación robusta."
        if ((Invoke-MenuPrompt -ValidChoices @('S','N') -PromptMessage "Desea que el script intente instalarlo ahora?") -eq 'S') {
            Write-Styled -Type Info -Message "Instalando módulo 'Microsoft.WinGet.Client'..."
            try {
                Install-Module -Name Microsoft.WinGet.Client -Scope CurrentUser -Force -AllowClobber -AcceptLicense -ErrorAction Stop
                Write-Styled -Type Success -Message "Módulo instalado correctamente."
            } catch {
                Write-Styled -Type Error -Message "La instalación automática del módulo de Winget falló: $($_.Exception.Message)"
                Write-Styled -Type Warn -Message "El script continuará usando el método de reserva (CLI)."
                $Global:UseWingetCli = $true
            }
        } else {
            Write-Styled -Type Warn -Message "Instalación denegada. El script usará el método de reserva para Winget."
            $Global:UseWingetCli = $true
        }
    } else {
        Write-Host " [ÉXITO]" -F $Global:Theme.Success
    }

    if (-not $allChecksPassed) {
        Pause-And-Return -Message "Una o más dependencias críticas no fueron satisfechas. Volviendo al menú principal."
    }
    return $allChecksPassed
}

function Invoke-Phase2_SoftwareMenu {
    param([string]$CatalogPath)
    
    if (-not (Invoke-Phase2_PreFlightChecks)) {
        return # Salir si las comprobaciones fallan
    }

    $chocoCatalogFile = Join-Path $CatalogPath "chocolatey_catalog.json"
    $wingetCatalogFile = Join-Path $CatalogPath "winget_catalog.json"
    if (-not (Test-Path $chocoCatalogFile) -or -not (Test-Path $wingetCatalogFile)) {
        Write-Styled -Type Error -Message "No se encontraron los archivos de catálogo en '${CatalogPath}'."
        Pause-And-Return
        return
    }

    $exitSubMenu = $false
    while (-not $exitSubMenu) {
        Show-Header -Title "FASE 2: Instalación de Software"
        Write-Styled -Type Step -Message "[1] Administrar paquetes de Chocolatey"
        Write-Styled -Type Step -Message "[2] Administrar paquetes de Winget"
        Write-Styled -Type Step -Message "[3] Instalar TODOS los paquetes de ambos catálogos (ideal para equipos nuevos)"
        Write-Styled -Type Step -Message "[0] Volver al Menú Principal"
        Write-Host

        $choice = Invoke-MenuPrompt -ValidChoices @('1', '2', '3', '0') -PromptMessage "Seleccione una opción"

        switch ($choice) {
            '1' {
                Invoke-SoftwareManagerUI -Manager 'Chocolatey' -CatalogFile $chocoCatalogFile
            }
            '2' {
                Invoke-SoftwareManagerUI -Manager 'Winget' -CatalogFile $wingetCatalogFile
            }
            '3' {
                Write-Styled -Type Consent -Message "Esta opción instalará TODOS los paquetes no instalados de AMBOS catálogos."
                if ((Invoke-MenuPrompt -ValidChoices @('S','N') -PromptMessage "¿Está seguro que desea continuar?") -eq 'S') {
                    # Lógica de instalación masiva
                    $catalogs = @(
                        @{ Manager = 'Chocolatey'; CatalogFile = $chocoCatalogFile },
                        @{ Manager = 'Winget'; CatalogFile = $wingetCatalogFile }
                    )
                    foreach ($catalogInfo in $catalogs) {
                        $manager = $catalogInfo.Manager
                        Show-Header -Title "Instalación Masiva: ${manager}"
                        $catalogPackages = (Get-Content -Raw -Path $catalogInfo.CatalogFile -Encoding UTF8 | ConvertFrom-Json).items
                        $statusFunction = if ($manager -eq 'Chocolatey') { Get-Command '_Get-ChocolateyPackageStatus' } else { Get-Command '_Get-WingetPackageStatus' }
                        $packageStatusList = & $statusFunction -CatalogPackages $catalogPackages

                        $packagesToInstall = $packageStatusList | Where-Object { $_.Status -eq 'No Instalado' }
                        if ($packagesToInstall.Count -gt 0) {
                             Write-Styled -Type Info -Message "Instalando $($packagesToInstall.Count) paquetes de ${manager}..."
                             foreach ($item in $packagesToInstall) {
                                _Install-Package -Manager $manager -Item $item
                             }
                        } else {
                            Write-Styled -Type Info -Message "No hay paquetes nuevos para instalar de ${manager}."
                        }
                    }
                    Pause-And-Return
                }
            }
            '0' {
                $exitSubMenu = $true
            }
        }
    }
}
#endregion