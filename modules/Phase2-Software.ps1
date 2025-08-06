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

    # Usar invocación de proceso directa para Chocolatey para evitar problemas de I/O con Start-Job.
    Write-Styled -Type Info -Message "Consultando paquetes de Chocolatey instalados..."
    $installedPackages = @{}
    try {
        $listOutput = choco list --limit-output 2>&1
        if ($LASTEXITCODE -ne 0) { throw "choco list falló con código de salida $LASTEXITCODE" }
        $listOutput | ForEach-Object {
            $id, $version = $_ -split '\|'; if ($id) { $installedPackages[$id.Trim()] = $version.Trim() }
        }
    } catch {
        Write-Styled -Type Error -Message "No se pudo obtener la lista de paquetes instalados con Chocolatey: $($_.Exception.Message)"
        return $null
    }

    Write-Styled -Type Info -Message "Buscando actualizaciones para paquetes de Chocolatey..."
    $outdatedPackages = @{}
    try {
        $outdatedOutput = choco outdated --limit-output 2>&1
        if ($LASTEXITCODE -ne 0) { throw "choco outdated falló con código de salida $LASTEXITCODE" }
        $outdatedOutput | ForEach-Object {
            $id, $current, $available, $pinned = $_ -split '\|'; if ($id) { $outdatedPackages[$id.Trim()] = @{ Current = $current.Trim(); Available = $available.Trim() } }
        }
    } catch {
        # Es posible que no haya paquetes desactualizados, lo que puede generar un error. No es un fallo crítico.
        Write-Styled -Type Info -Message "No se encontraron paquetes de Chocolatey para actualizar o hubo un error no crítico al verificar."
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

# Lógica de procesamiento de catálogo compartida para Winget
function _Process-WingetCatalog {
    param(
        [array]$CatalogPackages,
        [hashtable]$InstalledMap,
        [hashtable]$UpgradableMap,
        [hashtable]$InstalledMapByName,
        [hashtable]$UpgradableMapByName
    )
    $packageStatusList = @()
    for ($i = 0; $i -lt $CatalogPackages.Count; $i++) {
        $pkg = $CatalogPackages[$i]; $installId = $pkg.installId
        $displayName = if ($pkg.name) { $pkg.name } else { $installId }
        Write-Progress -Activity "Procesando estado de paquetes Winget" -Status "Verificando: ${displayName}" -PercentComplete (($i / $CatalogPackages.Count) * 100)

        $status = "No Instalado"; $versionInfo = ""; $isUpgradable = $false

        $useNameCheck = -not [string]::IsNullOrEmpty($pkg.checkName)
        $key = if ($useNameCheck) { $pkg.checkName } else { $installId }
        $currentInstalledMap = if ($useNameCheck) { $InstalledMapByName } else { $InstalledMap }
        $currentUpgradableMap = if ($useNameCheck) { $UpgradableMapByName } else { $UpgradableMap }

        if ($currentUpgradableMap.ContainsKey($key)) {
            $status = "Actualización Disponible"
            $versionInfo = "(v$($currentUpgradableMap[$key].Current) -> v$($currentUpgradableMap[$key].Available))"
            $isUpgradable = $true
        } elseif ($currentInstalledMap.ContainsKey($key)) {
            $status = "Instalado"
            $versionInfo = "(v$($currentInstalledMap[$key]))"
        }

        $packageStatusList += [PSCustomObject]@{
            DisplayName  = $displayName; Package = $pkg; Status = $status
            VersionInfo  = $versionInfo; IsUpgradable = $isUpgradable
        }
    }
    Write-Progress -Activity "Procesando estado de paquetes Winget" -Completed
    return $packageStatusList
}

function _Get-WingetPackageStatus {
    param([array]$CatalogPackages)

    if ($Global:UseWingetCli -or -not (Get-Module -ListAvailable -Name Microsoft.WinGet.Client)) {
        return _Get-WingetPackageStatus_Cli -CatalogPackages $CatalogPackages
    }
    try {
        Import-Module Microsoft.WinGet.Client -ErrorAction Stop
    } catch {
        Write-Styled -Type Error -Message "No se pudo importar el módulo 'Microsoft.WinGet.Client'."; Write-Styled -Type Warn -Message "Cambiando a método de reserva para Winget."
        return _Get-WingetPackageStatus_Cli -CatalogPackages $CatalogPackages
    }

    Write-Styled -Type Info -Message "Consultando todos los paquetes de Winget a través del módulo..."
    try {
        $allPackages = Get-WinGetPackage
        $installedById = $allPackages | Where-Object { $_.InstalledVersion } | Group-Object -Property Id -AsHashTable -AsString
        $installedByName = $allPackages | Where-Object { $_.InstalledVersion } | Group-Object -Property Name -AsHashTable -AsString

        $upgradableById = $allPackages | Where-Object { $_.AvailableVersion } | Group-Object -Property Id -AsHashTable -AsString
        $upgradableByName = $allPackages | Where-Object { $_.AvailableVersion } | Group-Object -Property Name -AsHashTable -AsString

        # Para los mapas de versiones, necesitamos extraer la propiedad correcta
        $installedVersionsById = @{}; $installedById.GetEnumerator() | ForEach-Object { $installedVersionsById[$_.Name] = $_.Value[0].InstalledVersion }
        $installedVersionsByName = @{}; $installedByName.GetEnumerator() | ForEach-Object { $installedVersionsByName[$_.Name] = $_.Value[0].InstalledVersion }
        $upgradableVersionsById = @{}; $upgradableById.GetEnumerator() | ForEach-Object { $upgradableVersionsById[$_.Name] = @{ Current = $_.Value[0].InstalledVersion; Available = $_.Value[0].AvailableVersion } }
        $upgradableVersionsByName = @{}; $upgradableByName.GetEnumerator() | ForEach-Object { $upgradableVersionsByName[$_.Name] = @{ Current = $_.Value[0].InstalledVersion; Available = $_.Value[0].AvailableVersion } }

    } catch {
        Write-Styled -Type Error -Message "Fallo crítico al obtener la lista de paquetes de Winget: $($_.Exception.Message)"; return $null
    }

    return _Process-WingetCatalog -CatalogPackages $CatalogPackages -InstalledMap $installedVersionsById -UpgradableMap $upgradableVersionsById -InstalledMapByName $installedVersionsByName -UpgradableMapByName $upgradableVersionsByName
}

function _Get-WingetPackageStatus_Cli {
    param([array]$CatalogPackages)

    Write-Styled -Type Info -Message "Consultando todos los paquetes de Winget (CLI)..."

    $listResult = Invoke-NativeCommand -Executable "winget" -ArgumentList "list --accept-source-agreements --disable-interactivity" -Activity "Listando todos los paquetes de Winget"
    $upgradeResult = Invoke-NativeCommand -Executable "winget" -ArgumentList "upgrade --include-unknown --accept-source-agreements --disable-interactivity" -Activity "Buscando todas las actualizaciones de Winget"

    $installedById = @{}; $installedByName = @{}
    if ($listResult.Success) {
        $listResult.Output -split "`n" | Select-Object -Skip 2 | ForEach-Object {
            $parts = $_.Trim() -split '\s{2,}' | Where-Object { $_ }
            if ($parts.Count -ge 3) {
                $name = ($parts[0..($parts.Count - 3)] -join ' ').Trim(); $id = $parts[-2].Trim(); $version = $parts[-1].Trim()
                if ($id) { $installedById[$id] = $version }; if ($name) { $installedByName[$name] = $version }
            }
        }
    }

    $upgradableById = @{}; $upgradableByName = @{}
    if ($upgradeResult.Success) {
        $upgradeResult.Output -split "`n" | Select-Object -Skip 2 | ForEach-Object {
            $parts = $_.Trim() -split '\s{2,}' | Where-Object { $_ }
            if ($parts.Count -ge 4) {
                $name = ($parts[0..($parts.Count - 4)] -join ' ').Trim(); $id = $parts[-3].Trim()
                $currentVersion = $parts[-2].Trim(); $availableVersion = $parts[-1].Trim()
                $versionInfo = @{ Current = $currentVersion; Available = $availableVersion }
                if ($id) { $upgradableById[$id] = $versionInfo }; if ($name) { $upgradableByName[$name] = $versionInfo }
            }
        }
    }
    return _Process-WingetCatalog -CatalogPackages $CatalogPackages -InstalledMap $installedById -UpgradableMap $upgradableById -InstalledMapByName $installedByName -UpgradableMapByName $upgradableByName
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
    if ($pkg.rebootRequired) { $global:RebootIsPending = $true }
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
    if ($pkg.rebootRequired) { $global:RebootIsPending = $true }
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

# Variables de caché a nivel de script para el estado de los paquetes
$script:chocolateyStatusCache = $null
$script:wingetStatusCache = $null

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

        # Determinar qué caché usar y obtener su valor
        $packageStatusList = if ($Manager -eq 'Chocolatey') { $script:chocolateyStatusCache } else { $script:wingetStatusCache }

        if ($null -eq $packageStatusList) {
            Write-Styled -Type Info -Message "Obteniendo estado de los paquetes para ${Manager} (puede tardar)..."
            $packageStatusList = if ($Manager -eq 'Chocolatey') {
                _Get-ChocolateyPackageStatus -CatalogPackages $catalogPackages
            } else {
                _Get-WingetPackageStatus -CatalogPackages $catalogPackages
            }
            # Guardar el resultado en la caché correcta
            if ($Manager -eq 'Chocolatey') { $script:chocolateyStatusCache = $packageStatusList } else { $script:wingetStatusCache = $packageStatusList }
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
             'A' = 'Aplicar todas las instalaciones y actualizaciones pendientes.'
             'R' = 'Refrescar la lista de paquetes.'
             '0' = 'Volver al menú anterior.'
        }

        $choice = Invoke-StandardMenu -Title "FASE 2: Administrador de Paquetes (${Manager})" -MenuItems $menuItems -ActionOptions $actionOptions

        switch ($choice) {
            'A' {
                $packagesToProcess = $packageStatusList | Where-Object { $_.Status -eq 'No Instalado' -or $_.IsUpgradable }
                if ($packagesToProcess.Count -gt 0) {
                    Write-Styled -Type Info -Message "Procesando $($packagesToProcess.Count) paquetes..."
                    try {
                        foreach ($item in $packagesToProcess) {
                            if ($item.IsUpgradable) {
                                _Update-Package -Manager $Manager -Item $item
                            } else {
                                _Install-Package -Manager $Manager -Item $item
                            }
                        }
                        # Invalidar la caché correcta
                        if ($Manager -eq 'Chocolatey') { $script:chocolateyStatusCache = $null } else { $script:wingetStatusCache = $null }
                    } catch {
                        Write-Styled -Type Error -Message "Ocurrió un error durante el procesamiento masivo."
                        Pause-And-Return
                    }
                } else {
                    Write-Styled -Type Info -Message "No hay paquetes para instalar o actualizar."; Start-Sleep -Seconds 2
                }
            }
            'R' {
                if ($Manager -eq 'Chocolatey') { $script:chocolateyStatusCache = $null } else { $script:wingetStatusCache = $null }
                continue
            }
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

function Invoke-SoftwareSearchAndInstall {
    [CmdletBinding()]
    param()

    Show-Header -Title "Búsqueda e Instalación de Paquetes (Winget)"
    $searchTerm = Read-Host "Introduzca el nombre o ID del paquete a buscar"
    if (-not $searchTerm) { return }

    Write-Styled -Type Info -Message "Buscando '$($searchTerm)' con Winget..."
    $searchResult = Invoke-NativeCommand -Executable "winget" -ArgumentList "search `"$searchTerm`" --accept-source-agreements" -Activity "Buscando en Winget"

    if (-not $searchResult.Success -or $searchResult.Output -match "No package found matching input criteria") {
        Write-Styled -Type Error -Message "No se encontraron paquetes que coincidan con '$searchTerm'."
        Pause-And-Return
        return
    }

    Write-Host $searchResult.Output
    Write-Styled -Type Consent -Message "Se encontraron los paquetes de arriba."
    $idToInstall = Read-Host "Escriba el ID exacto del paquete que desea instalar (o presione Enter para cancelar)"

    if ($idToInstall) {
        $item = [PSCustomObject]@{
            DisplayName = $idToInstall
            Package     = [PSCustomObject]@{ installId = $idToInstall }
        }
        _Install-Package -Manager 'Winget' -Item $item
        Pause-And-Return
    }
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

                        $packagesToProcess = $packageStatusList | Where-Object { $_.Status -eq 'No Instalado' -or $_.IsUpgradable }
                        if ($packagesToProcess.Count -gt 0) {
                             Write-Styled -Type Info -Message "Procesando $($packagesToProcess.Count) paquetes de ${manager}..."
                             foreach ($item in $packagesToProcess) {
                                if ($item.IsUpgradable) {
                                    _Update-Package -Manager $manager -Item $item
                                } else {
                                    _Install-Package -Manager $manager -Item $item
                                }
                             }
                        } else {
                            Write-Styled -Type Info -Message "No hay paquetes nuevos para instalar o actualizar de ${manager}."
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