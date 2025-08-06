<#
.SYNOPSIS
    Módulo de Fase 2 para la instalación de software desde manifiestos.
.DESCRIPTION
    Contiene la lógica para cargar catálogos de Chocolatey y Winget, y presenta
    un submenú para permitir la instalación granular o completa de los paquetes.
.NOTES
    Versión: 2.1
    Autor: miguel-cinsfran
#>

#region Proveedores de Gestores de Paquetes

$script:PackageManagers = @{
    Chocolatey = [PSCustomObject]@{
        Name           = 'Chocolatey'
        Executable     = 'choco'
        Commands       = @{
            Install   = 'install {installId} -y {params}'
            Upgrade   = 'upgrade {installId} -y'
            Uninstall = 'uninstall {installId} -y'
        }
        StatusChecker  = { param($packages) _Get-ChocolateyPackageStatus -CatalogPackages $packages }
        FailureStrings = @("not found", "was not found", "no se encontró")
    }
    Winget = [PSCustomObject]@{
        Name           = 'Winget'
        Executable     = 'winget'
        Commands       = @{
            # Winget usa 'install' para actualizar si el paquete ya existe
            Install   = 'install --id {installId} --accept-package-agreements --accept-source-agreements {source}'
            Upgrade   = 'install --id {installId} --accept-package-agreements --accept-source-agreements'
            Uninstall = 'uninstall --id {installId} --accept-package-agreements --silent'
        }
        StatusChecker  = { param($packages) _Get-WingetPackageStatus -CatalogPackages $packages }
        FailureStrings = @("No package found", "No se encontró ningún paquete")
    }
}

#endregion

function _Execute-SoftwareJob {
    param(
        [string]$PackageName,
        [string]$Executable,
        [string]$ArgumentList,
        [string[]]$FailureStrings
    )

    # Definir el patrón regex para el progreso basado en el ejecutable.
    $progressRegex = ''
    switch ($Executable) {
        'choco'  { $progressRegex = 'Progress:\s*(\d+)%' }
        'winget' { $progressRegex = '\s(\d+)\s*%' }
    }

    # Deshabilitar el timeout de inactividad para instalaciones de software,
    # ya que pueden tener largos periodos de descarga sin actividad en la consola.
    $result = Invoke-NativeCommand -Executable $Executable -ArgumentList $ArgumentList -FailureStrings $FailureStrings -Activity "Ejecutando: ${Executable} ${ArgumentList}" -IdleTimeoutEnabled $false -ProgressRegex $progressRegex

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

#region Lógica de Estado de Paquetes (Abstraída)

# Función genérica para comparar un catálogo con mapas de paquetes instalados/actualizables.
function _Get-PackageStatusFromMaps {
    param(
        [string]$ManagerName,
        [array]$CatalogPackages,
        [hashtable]$InstalledMap,
        [hashtable]$UpgradableMap,
        [hashtable]$InstalledMapByName,
        [hashtable]$UpgradableMapByName
    )
    $packageStatusList = @()
    for ($i = 0; $i -lt $CatalogPackages.Count; $i++) {
        $pkg = $CatalogPackages[$i]
        $installId = $pkg.installId
        $displayName = if ($pkg.name) { $pkg.name } else { $installId }

        Write-Progress -Activity "Procesando estado de paquetes de $ManagerName" -Status "Verificando: $displayName" -PercentComplete (($i / $CatalogPackages.Count) * 100)

        $status = "No Instalado"
        $versionInfo = ""
        $isUpgradable = $false

        # Determinar si usar el nombre del paquete para la comprobación (para casos como WhatsApp de la MS Store)
        $useNameCheck = $InstalledMapByName -and (-not [string]::IsNullOrEmpty($pkg.checkName))
        $key = if ($useNameCheck) { $pkg.checkName } else { $installId }
        $currentInstalledMap = if ($useNameCheck) { $InstalledMapByName } else { $InstalledMap }
        $currentUpgradableMap = if ($useNameCheck) { $UpgradableMapByName } else { $UpgradableMap }

        if ($currentUpgradableMap -and $currentUpgradableMap.ContainsKey($key)) {
            $status = "Actualización Disponible"
            $versionInfo = "(v$($currentUpgradableMap[$key].Current) -> v$($currentUpgradableMap[$key].Available))"
            $isUpgradable = $true
        } elseif ($currentInstalledMap -and $currentInstalledMap.ContainsKey($key)) {
            $status = "Instalado"
            # El valor puede ser un string (choco) o un hashtable (winget)
            $installedVersion = if ($currentInstalledMap[$key] -is [string]) { $currentInstalledMap[$key] } else { $currentInstalledMap[$key].Current }
            $versionInfo = "(v$($installedVersion))"
        }

        $packageStatusList += [PSCustomObject]@{
            DisplayName  = $displayName
            Package      = $pkg
            Status       = $status
            VersionInfo  = $versionInfo
            IsUpgradable = $isUpgradable
        }
    }
    Write-Progress -Activity "Procesando estado de paquetes de $ManagerName" -Completed
    return $packageStatusList
}

# --- Lógica específica de Chocolatey ---

function _Get-ChocolateyInstalledData {
    $installedPackages = @{}
    $upgradablePackages = @{}

    Write-Styled -Type Info -Message "Consultando paquetes de Chocolatey instalados..."
    try {
        $listOutput = choco list --limit-output 2>&1
        if ($LASTEXITCODE -ne 0) { throw "choco list falló con código de salida $LASTEXITCODE" }
        $listOutput | ForEach-Object {
            $id, $version = $_ -split '\|'; if ($id) { $installedPackages[$id.Trim()] = $version.Trim() }
        }
    } catch {
        throw "No se pudo obtener la lista de paquetes instalados con Chocolatey: $($_.Exception.Message)"
    }

    Write-Styled -Type Info -Message "Buscando actualizaciones para paquetes de Chocolatey..."
    try {
        $outdatedOutput = choco outdated --limit-output 2>&1
        if ($LASTEXITCODE -ne 0) { throw "choco outdated falló con código de salida $LASTEXITCODE" }
        $outdatedOutput | ForEach-Object {
            $id, $current, $available, $pinned = $_ -split '\|'; if ($id) { $upgradablePackages[$id.Trim()] = @{ Current = $current.Trim(); Available = $available.Trim() } }
        }
    } catch {
        Write-Styled -Type Info -Message "No se encontraron paquetes de Chocolatey para actualizar o hubo un error no crítico al verificar."
    }

    return [PSCustomObject]@{
        InstalledMap = $installedPackages
        UpgradableMap = $upgradablePackages
    }
}

function _Get-ChocolateyPackageStatus {
    param([array]$CatalogPackages)
    try {
        $chocoData = _Get-ChocolateyInstalledData
        return _Get-PackageStatusFromMaps -ManagerName 'Chocolatey' -CatalogPackages $CatalogPackages -InstalledMap $chocoData.InstalledMap -UpgradableMap $chocoData.UpgradableMap
    } catch {
        Write-Styled -Type Error -Message $_.Exception.Message
        return $null
    }
}

# --- Lógica específica de Winget ---

function _Parse-WingetListLine {
    param([string]$Line)
    $line = $Line.TrimEnd()
    if ([string]::IsNullOrWhiteSpace($line)) { return $null }
    $parts = $line -split '\s{2,}' | Where-Object { $_ }
    if ($parts.Count -lt 3) { return $null }
    $source = if ($parts[-1] -in @('winget', 'msstore')) { $parts[-1] } else { "" }
    if ($source) { $parts = $parts[0..($parts.Count - 2)] }
    if ($parts.Count -lt 3) { return $null }
    $name = ""; $id = ""; $version = ""; $available = ""
    if ($parts.Count -ge 4) {
        $available = $parts[-1]; $version = $parts[-2]; $id = $parts[-3]; $name = ($parts[0..($parts.Count - 4)] -join ' ').Trim()
    } else {
        $version = $parts[-1]; $id = $parts[-2]; $name = ($parts[0..($parts.Count - 3)] -join ' ').Trim()
    }
    if ($available -in @('<unknown>', '<desconocido>')) { $available = "" }
    return [PSCustomObject]@{ Name = $name; Id = $id; Version = $version; Available = $available; Source = $source }
}

function _Get-WingetInstalledData_Cli {
    $installedById = @{}; $installedByName = @{}; $upgradableById = @{}; $upgradableByName = @{}

    Write-Styled -Type Info -Message "Consultando todos los paquetes de Winget (CLI)..."
    $listResult = Invoke-NativeCommand -Executable "winget" -ArgumentList "list --include-unknown --accept-source-agreements --disable-interactivity" -Activity "Listando todos los paquetes de Winget"
    if (-not $listResult.Success) { throw "El comando 'winget list' falló." }

    $lines = $listResult.Output -split "`n"
    $dataStartIndex = 0
    while ($dataStartIndex -lt $lines.Length -and $lines[$dataStartIndex] -notmatch '^-+$') { $dataStartIndex++ }
    $dataStartIndex++

    if ($dataStartIndex -ge $lines.Length) {
        Write-Styled -Type Warn -Message "No se encontraron datos de paquetes en la salida de winget."
    } else {
        $lines | Select-Object -Skip $dataStartIndex | ForEach-Object {
            $parsed = _Parse-WingetListLine -Line $_
            if (-not $parsed) { return }
            if ($parsed.Id) { $installedById[$parsed.Id] = $parsed.Version }
            if ($parsed.Name) { $installedByName[$parsed.Name] = $parsed.Version }
            if ($parsed.Available) {
                $versionInfo = @{ Current = $parsed.Version; Available = $parsed.Available }
                if ($parsed.Id) { $upgradableById[$parsed.Id] = $versionInfo }
                if ($parsed.Name) { $upgradableByName[$parsed.Name] = $versionInfo }
            }
        }
    }

    return [PSCustomObject]@{
        InstalledMap = $installedById; UpgradableMap = $upgradableById
        InstalledMapByName = $installedByName; UpgradableMapByName = $upgradableByName
    }
}

function _Get-WingetInstalledData_Module {
    $installedVersionsById = @{}; $installedVersionsByName = @{}
    $upgradableVersionsById = @{}; $upgradableVersionsByName = @{}

    Write-Styled -Type Info -Message "Consultando todos los paquetes de Winget a través del módulo..."
    $allPackages = Get-WinGetPackage
    if ($null -ne $allPackages) {
        $installedById = $allPackages | Where-Object { $_.InstalledVersion } | Group-Object -Property Id -AsHashTable -AsString
        $installedByName = $allPackages | Where-Object { $_.InstalledVersion } | Group-Object -Property Name -AsHashTable -AsString
        $upgradableById = $allPackages | Where-Object { $_.AvailableVersion -and $_.InstalledVersion } | Group-Object -Property Id -AsHashTable -AsString
        $upgradableByName = $allPackages | Where-Object { $_.AvailableVersion -and $_.InstalledVersion } | Group-Object -Property Name -AsHashTable -AsString

        if ($null -ne $installedById) { $installedById.GetEnumerator() | ForEach-Object { $installedVersionsById[$_.Name] = $_.Value[0].InstalledVersion } }
        if ($null -ne $installedByName) { $installedByName.GetEnumerator() | ForEach-Object { $installedVersionsByName[$_.Name] = $_.Value[0].InstalledVersion } }
        if ($null -ne $upgradableById) { $upgradableById.GetEnumerator() | ForEach-Object { $upgradableVersionsById[$_.Name] = @{ Current = $_.Value[0].InstalledVersion; Available = $_.Value[0].AvailableVersion } } }
        if ($null -ne $upgradableByName) { $upgradableByName.GetEnumerator() | ForEach-Object { $upgradableVersionsByName[$_.Name] = @{ Current = $_.Value[0].InstalledVersion; Available = $_.Value[0].AvailableVersion } } }
    }

    return [PSCustomObject]@{
        InstalledMap = $installedVersionsById; UpgradableMap = $upgradableVersionsById
        InstalledMapByName = $installedVersionsByName; UpgradableMapByName = $upgradableVersionsByName
    }
}

function _Get-WingetPackageStatus {
    param([array]$CatalogPackages)

    $wingetData = $null
    try {
        if ($Global:UseWingetCli -or -not (Get-Module -ListAvailable -Name Microsoft.WinGet.Client)) {
            $wingetData = _Get-WingetInstalledData_Cli
        } else {
            try {
                Import-Module Microsoft.WinGet.Client -ErrorAction Stop
                $wingetData = _Get-WingetInstalledData_Module
            } catch {
                Write-Styled -Type Error -Message "No se pudo importar 'Microsoft.WinGet.Client'. Cambiando a método de reserva."
                $wingetData = _Get-WingetInstalledData_Cli
            }
        }
        return _Get-PackageStatusFromMaps -ManagerName 'Winget' -CatalogPackages $CatalogPackages -InstalledMap $wingetData.InstalledMap -UpgradableMap $wingetData.UpgradableMap -InstalledMapByName $wingetData.InstalledMapByName -UpgradableMapByName $wingetData.UpgradableMapByName
    } catch {
        Write-Styled -Type Error -Message "Fallo crítico al obtener la lista de paquetes de Winget: $($_.Exception.Message)"
        return $null
    }
}

#endregion

#region Package Action Helpers

function _Invoke-PackageAction {
    param(
        [string]$Manager,
        [string]$Action, # "Install", "Upgrade", "Uninstall"
        [PSCustomObject]$Item
    )

    $provider = $script:PackageManagers[$Manager]
    if (-not $provider) {
        throw "Proveedor de paquetes desconocido: $Manager"
    }

    $commandTemplate = $provider.Commands[$Action]
    $pkg = $Item.Package

    # Reemplazar placeholders en la plantilla del comando
    $argumentList = $commandTemplate -replace '\{installId\}', $pkg.installId

    # Manejar parámetros especiales/opcionales
    if ($commandTemplate -match '\{params\}') {
        $paramString = ""
        if ($pkg.PSObject.Properties.Match('special_params') -and $pkg.special_params) {
            $paramString = "--params='$($pkg.special_params)'"
        }
        $argumentList = $argumentList -replace '\{params\}', $paramString
    }

    if ($commandTemplate -match '\{source\}') {
        $sourceString = ""
        if ($pkg.PSObject.Properties.Match('source') -and $pkg.source) {
            $sourceString = "--source $($pkg.source)"
        }
        $argumentList = $argumentList -replace '\{source\}', $sourceString
    }

    # Limpiar espacios extra si los placeholders opcionales estaban vacíos
    $argumentList = $argumentList -replace '\s+', ' ' | ForEach-Object { $_.Trim() }

    _Execute-SoftwareJob -PackageName $Item.DisplayName -Executable $provider.Executable -ArgumentList $argumentList -FailureStrings $provider.FailureStrings

    # Tareas post-acción (solo para instalación y actualización)
    if ($Action -in @('Install', 'Upgrade')) {
        if ($pkg.PSObject.Properties.Match('postInstallConfig') -and $pkg.postInstallConfig) {
            Invoke-PostInstallConfiguration -Package $pkg
        }
        if ($pkg.rebootRequired) { $global:RebootIsPending = $true }
    }
}

function _Invoke-ProcessPendingPackages {
    param(
        [string]$Manager,
        [array]$PackageStatusList
    )
    $packagesToProcess = $PackageStatusList | Where-Object { $_.Status -eq 'No Instalado' -or $_.IsUpgradable }
    if ($packagesToProcess.Count -gt 0) {
        Write-Styled -Type Info -Message "Procesando $($packagesToProcess.Count) paquetes para ${Manager}..."
        try {
            foreach ($item in $packagesToProcess) {
                if ($item.IsUpgradable) {
                    _Update-Package -Manager $Manager -Item $item
                } else {
                    _Install-Package -Manager $Manager -Item $item
                }
            }
            # Invalidar la caché después del procesamiento masivo
            if ($Manager -eq 'Chocolatey') { $script:chocolateyStatusCache = $null } else { $script:wingetStatusCache = $null }
        } catch {
            Write-Styled -Type Error -Message "Ocurrió un error durante el procesamiento masivo para ${Manager}."
            Pause-And-Return -Message "`nRevise el error anterior. Presione Enter para volver al menú."
        }
    } else {
        Write-Styled -Type Info -Message "No hay paquetes para instalar o actualizar para ${Manager}."
        Start-Sleep -Seconds 2
    }
}

function _Install-Package {
    param([string]$Manager, [PSCustomObject]$Item)
    _Invoke-PackageAction -Manager $Manager -Action 'Install' -Item $Item
}

function _Uninstall-Package {
    param([string]$Manager, [PSCustomObject]$Item)
    _Invoke-PackageAction -Manager $Manager -Action 'Uninstall' -Item $Item
}

function _Update-Package {
    param([string]$Manager, [PSCustomObject]$Item)
    _Invoke-PackageAction -Manager $Manager -Action 'Upgrade' -Item $Item
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
            'I' {
                _Install-Package -Manager $Manager -Item $Item
                if ($Manager -eq 'Chocolatey') { $script:chocolateyStatusCache = $null } else { $script:wingetStatusCache = $null }
                $exitMenu = $true
            }
            'A' {
                _Update-Package -Manager $Manager -Item $Item
                if ($Manager -eq 'Chocolatey') { $script:chocolateyStatusCache = $null } else { $script:wingetStatusCache = $null }
                $exitMenu = $true
            }
            'D' {
                if ((Invoke-MenuPrompt -ValidChoices @('S','N') -PromptMessage "Está seguro que desea desinstalar $($Item.DisplayName)?") -eq 'S') {
                    _Uninstall-Package -Manager $Manager -Item $Item
                    if ($Manager -eq 'Chocolatey') { $script:chocolateyStatusCache = $null } else { $script:wingetStatusCache = $null }
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
        $catalogJson = Get-Content -Raw -Path $CatalogFile -Encoding UTF8 | ConvertFrom-Json
        if (-not (Test-SoftwareCatalog -CatalogData $catalogJson -CatalogFileName (Split-Path $CatalogFile -Leaf))) {
            Pause-And-Return -Message "`nEl catálogo de software no es válido. Presione Enter para volver."
            return
        }
        $catalogPackages = $catalogJson.items
    } catch {
        Write-Styled -Type Error -Message "Fallo CRÍTICO al leer o procesar '${CatalogFile}': $($_.Exception.Message)"
        Pause-And-Return -Message "`nRevise el error anterior. Presione Enter para volver al menú."
        return
    }

    # Asignar dinámicamente la función de estado y el nombre de la variable de caché.
    $statusFunctionName = "_Get-${Manager}PackageStatus"
    $cacheVariableName = "script:${Manager}StatusCache"

    $exitManagerUI = $false
    while (-not $exitManagerUI) {
        # Obtener el estado de los paquetes, usando la caché si está disponible.
        $packageStatusList = Get-Variable -Name $cacheVariableName -ErrorAction SilentlyContinue -ValueOnly
        if ($null -eq $packageStatusList) {
            Write-Styled -Type Info -Message "Obteniendo estado de los paquetes para ${Manager} (puede tardar)..."
            $packageStatusList = & (Get-Command $statusFunctionName) -CatalogPackages $catalogPackages
            Set-Variable -Name $cacheVariableName -Value $packageStatusList
        }

        if ($null -eq $packageStatusList) {
            Write-Styled -Type Error -Message "No se pudo continuar debido a un error al obtener el estado de los paquetes."
            Pause-And-Return -Message "`nRevise el error anterior. Presione Enter para volver al menú."
            return
        }

        # Construir y mostrar el menú estandarizado.
        $menuItems = $packageStatusList | ForEach-Object {
            [PSCustomObject]@{
                Description = "$($_.DisplayName) $($_.VersionInfo)".Trim()
                Status      = $_.Status
            }
        }
        $actionOptions = [ordered]@{
             'A' = 'Aplicar todas las instalaciones y actualizaciones pendientes.'
             'U' = 'Mostrar solo paquetes actualizables.'
             'R' = 'Refrescar la lista de paquetes.'
             '0' = 'Volver al menú anterior.'
        }
        $title = "FASE 2: Administrador de Paquetes (${Manager})"
        $choice = Invoke-StandardMenu -Title $title -MenuItems $menuItems -ActionOptions $actionOptions

        # Procesar la selección del usuario.
        switch ($choice) {
            'A' {
                _Invoke-ProcessPendingPackages -Manager $Manager -PackageStatusList $packageStatusList
                Set-Variable -Name $cacheVariableName -Value $null # Invalidar caché
            }
            'U' {
                $upgradableItems = $packageStatusList | Where-Object { $_.IsUpgradable }
                Show-Header -Title "Paquetes con Actualizaciones Disponibles (${Manager})"
                if ($upgradableItems.Count -gt 0) {
                    $upgradableItems | ForEach-Object { Write-Styled -Type Warn -Message "$($_.DisplayName) $($_.VersionInfo)" }
                } else {
                    Write-Styled -Type Info -Message "Todos los paquetes del catálogo están actualizados."
                }
                Pause-And-Return -Message "`nPresione Enter para volver al menú de paquetes."
            }
            'R' {
                Set-Variable -Name $cacheVariableName -Value $null # Invalidar caché
            }
            '0' { $exitManagerUI = $true }
            default { # Es un número (selección de paquete individual)
                $packageIndex = [int]$choice - 1
                $selectedItem = $packageStatusList[$packageIndex]
                _Invoke-SinglePackageMenu -Manager $Manager -Item $selectedItem
                # La caché se invalida dentro de _Invoke-SinglePackageMenu, pero hacerlo
                # de nuevo aquí es más seguro por si esa lógica cambia.
                Set-Variable -Name $cacheVariableName -Value $null
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
        Write-Styled -Type SubStep -Message "Actualizando repositorios de Winget..."
        Invoke-NativeCommand -Executable "winget" -ArgumentList "source update" -Activity "Actualizando repositorios de Winget" | Out-Null
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
        Pause-And-Return -Message "`nPresione Enter para volver al menú."
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
        Pause-And-Return -Message "`nOperación finalizada. Presione Enter para continuar."
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
        Pause-And-Return -Message "`nRevise el error anterior. Presione Enter para volver al menú."
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

                        # Obtener el estado de los paquetes
                        $statusFunction = if ($manager -eq 'Chocolatey') { Get-Command '_Get-ChocolateyPackageStatus' } else { Get-Command '_Get-WingetPackageStatus' }
                        $packageStatusList = & $statusFunction -CatalogPackages $catalogPackages

                        # Invocar la lógica de procesamiento centralizada
                        _Invoke-ProcessPendingPackages -Manager $manager -PackageStatusList $packageStatusList
                    }
                    # Invalidar ambas cachés después de una instalación masiva completa
                    $script:chocolateyStatusCache = $null
                    $script:wingetStatusCache = $null
                    Pause-And-Return -Message "`nInstalación masiva completada. Presione Enter para volver al menú."
                }
            }
            '0' {
                $exitSubMenu = $true
            }
        }
    }
}
#endregion