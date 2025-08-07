<#
.SYNOPSIS
    Módulo de Fase 2 para la instalación de software desde manifiestos.
.DESCRIPTION
    Contiene la lógica para cargar catálogos de Chocolatey y Winget, y presenta
    un submenú para permitir la instalación granular o completa de los paquetes.
.NOTES
    Versión: 2.1
    Autor: miguel-cinsfran
    Revisión: Corregida la codificación de caracteres y mejorada la legibilidad y robustez.
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
    $installedVersionsById = @{}; $installedVersionsByName = @{}
    $upgradableVersionsById = @{}; $upgradableVersionsByName = @{}
    try {
        $allPackages = Get-WinGetPackage
        if ($null -ne $allPackages) {
            # Crear mapas duales por ID y por Nombre para manejar todos los casos del catálogo.
            $installedById = $allPackages | Where-Object { $_.InstalledVersion } | Group-Object -Property Id -AsHashTable -AsString
            $installedByName = $allPackages | Where-Object { $_.InstalledVersion } | Group-Object -Property Name -AsHashTable -AsString

            $upgradableById = $allPackages | Where-Object { $_.AvailableVersion -and $_.InstalledVersion } | Group-Object -Property Id -AsHashTable -AsString
            $upgradableByName = $allPackages | Where-Object { $_.AvailableVersion -and $_.InstalledVersion } | Group-Object -Property Name -AsHashTable -AsString

            # Para los mapas de versiones, necesitamos extraer la propiedad correcta, verificando que no sean nulos.
            if ($null -ne $installedById) { $installedById.GetEnumerator() | ForEach-Object { $installedVersionsById[$_.Name] = $_.Value[0].InstalledVersion } }
            if ($null -ne $installedByName) { $installedByName.GetEnumerator() | ForEach-Object { $installedVersionsByName[$_.Name] = $_.Value[0].InstalledVersion } }
            if ($null -ne $upgradableById) { $upgradableById.GetEnumerator() | ForEach-Object { $upgradableVersionsById[$_.Name] = @{ Current = $_.Value[0].InstalledVersion; Available = $_.Value[0].AvailableVersion } } }
            if ($null -ne $upgradableByName) { $upgradableByName.GetEnumerator() | ForEach-Object { $upgradableVersionsByName[$_.Name] = @{ Current = $_.Value[0].InstalledVersion; Available = $_.Value[0].AvailableVersion } } }
        }
    } catch {
        Write-Styled -Type Error -Message "Fallo crítico al obtener la lista de paquetes de Winget: $($_.Exception.Message)"; return $null
    }

    return _Process-WingetCatalog -CatalogPackages $CatalogPackages -InstalledMap $installedVersionsById -UpgradableMap $upgradableVersionsById -InstalledMapByName $installedVersionsByName -UpgradableMapByName $upgradableVersionsByName
}

function _Parse-WingetListLine {
    param([string]$Line)

    # El formato de salida de 'winget list' es de ancho fijo, lo que lo hace difícil de analizar
    # si un nombre de paquete contiene muchos espacios.
    # Ejemplo:
    # Nombre               Id                  Versión      Disponible   Fuente
    # --------------------------------------------------------------------------
    # Git                  Git.Git             2.39.2       2.40.0       winget
    # Google Chrome        Google.Chrome       110.0.5481.78
    # 7-Zip 22.01 (x64)    7zip.7zip           22.01

    $line = $Line.TrimEnd()
    if ([string]::IsNullOrWhiteSpace($line)) { return $null }

    # La estrategia más robusta es analizar de derecha a izquierda, ya que las últimas
    # columnas (Fuente, Disponible, Versión, Id) son más predecibles que el Nombre.
    $parts = $line -split '\s{2,}' | Where-Object { $_ }
    if ($parts.Count -lt 3) { return $null } # Línea malformada, no tiene suficientes columnas.

    # La última columna puede ser la fuente (o no).
    $source = ""
    if ($parts[-1] -in @('winget', 'msstore')) {
        $source = $parts[-1]
        $parts = $parts[0..($parts.Count - 2)] # Quitar la fuente de las partes a procesar.
    }

    if ($parts.Count -lt 3) { return $null } # Si después de quitar la fuente no quedan suficientes partes, la línea es inválida.

    # Asignación de columnas de derecha a izquierda.
    $name = ""; $id = ""; $version = ""; $available = ""

    if ($parts.Count -ge 4) { # Formato con 'Disponible': Nombre, Id, Versión, Disponible
        $available = $parts[-1]
        $version = $parts[-2]
        $id = $parts[-3]
        $name = ($parts[0..($parts.Count - 4)] -join ' ').Trim()
    } else { # Formato sin 'Disponible': Nombre, Id, Versión
        $version = $parts[-1]
        $id = $parts[-2]
        $name = ($parts[0..($parts.Count - 3)] -join ' ').Trim()
    }

    # Ignorar valores no útiles para la versión disponible.
    if ($available -in @('<unknown>', '<desconocido>')) {
        $available = ""
    }

    return [PSCustomObject]@{
        Name      = $name
        Id        = $id
        Version   = $version
        Available = $available
        Source    = $source
    }
}

function _Get-WingetPackageStatus_Cli {
    param([array]$CatalogPackages)

    Write-Styled -Type Info -Message "Consultando todos los paquetes de Winget (CLI)..."
    $listResult = Invoke-NativeCommand -Executable "winget" -ArgumentList "list --include-unknown --accept-source-agreements --disable-interactivity" -Activity "Listando todos los paquetes de Winget"

    if (-not $listResult.Success) {
        Write-Styled -Type Error -Message "El comando 'winget list' falló."
        return $null
    }

    $installedById = @{}; $installedByName = @{}
    $upgradableById = @{}; $upgradableByName = @{}

    $lines = $listResult.Output -split "`n"

    # Encontrar el inicio de los datos, que es después de la línea de guiones '----'.
    $dataStartIndex = 0
    while ($dataStartIndex -lt $lines.Length -and $lines[$dataStartIndex] -notmatch '^-+$') {
        $dataStartIndex++
    }
    $dataStartIndex++ # Moverse a la línea *después* de los guiones.

    if ($dataStartIndex -ge $lines.Length) {
        Write-Styled -Type Warn -Message "No se encontraron datos de paquetes en la salida de winget."
    } else {
        # Procesar cada línea de datos usando el parser robusto.
        $lines | Select-Object -Skip $dataStartIndex | ForEach-Object {
            $parsed = _Parse-WingetListLine -Line $_
            if (-not $parsed) { return } # Ignorar líneas en blanco o malformadas

            # Poblar los mapas de búsqueda.
            if ($parsed.Id) { $installedById[$parsed.Id] = $parsed.Version }
            if ($parsed.Name) { $installedByName[$parsed.Name] = $parsed.Version }

            if ($parsed.Available) {
                $versionInfo = @{ Current = $parsed.Version; Available = $parsed.Available }
                if ($parsed.Id) { $upgradableById[$parsed.Id] = $versionInfo }
                if ($parsed.Name) { $upgradableByName[$parsed.Name] = $versionInfo }
            }
        }
    }

    # Usar la función de procesamiento de catálogo existente con los datos recopilados.
    return _Process-WingetCatalog -CatalogPackages $CatalogPackages -InstalledMap $installedById -UpgradableMap $upgradableById -InstalledMapByName $installedByName -UpgradableMapByName $upgradableByName
}

#region Package Action Helpers

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
            Pause-And-Return
        }
    } else {
        Write-Styled -Type Info -Message "No hay paquetes para instalar o actualizar para ${Manager}."
        Start-Sleep -Seconds 2
    }
}

function _Install-Package {
    param([string]$Manager, [PSCustomObject]$Item)
    $pkg = $Item.Package
    if ($Manager -eq 'Chocolatey') {
        $chocoArgs = @("install", $pkg.installId, "-y")
        if ($pkg.special_params) { $chocoArgs += "--params='$($pkg.special_params)'" }
        _Execute-SoftwareJob -PackageName $Item.DisplayName -Executable "choco" -ArgumentList ($chocoArgs -join ' ') -FailureStrings "not found", "was not found"
    } else { # Winget
        $wingetArgs = @("install", "--id", $pkg.installId, "--accept-package-agreements", "--accept-source-agreements")
        if ($pkg.source) { $wingetArgs += "--source", $pkg.source }
        _Execute-SoftwareJob -PackageName $Item.DisplayName -Executable "winget" -ArgumentList ($wingetArgs -join ' ') -FailureStrings "No package found"
    }

    if ($pkg.PSObject.Properties.Match('postInstallConfig') -and $pkg.postInstallConfig) {
        Invoke-PostInstallConfiguration -Package $pkg
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
        $chocoArgs = @("upgrade", $pkg.installId, "-y")
        _Execute-SoftwareJob -PackageName $Item.DisplayName -Executable "choco" -ArgumentList ($chocoArgs -join ' ') -FailureStrings "not found", "was not found"
    } else { # Winget
        # Winget 'upgrade' es funcionalmente idéntico a 'install' para un paquete ya instalado.
        $wingetArgs = @("install", "--id", $pkg.installId, "--accept-package-agreements", "--accept-source-agreements")
        _Execute-SoftwareJob -PackageName $Item.DisplayName -Executable "winget" -ArgumentList ($wingetArgs -join ' ') -FailureStrings "No package found"
    }

    if ($pkg.PSObject.Properties.Match('postInstallConfig') -and $pkg.postInstallConfig) {
        Invoke-PostInstallConfiguration -Package $pkg
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
                if ((Invoke-MenuPrompt -ValidChoices @('S','N') -PromptMessage "¿Está seguro de que desea desinstalar $($Item.DisplayName)?") -eq 'S') {
                    _Uninstall-Package -Manager $Manager -Item $Item
                    if ($Manager -eq 'Chocolatey') { $script:chocolateyStatusCache = $null } else { $script:wingetStatusCache = $null }
                }
                $exitMenu = $true
            }
            '0' { $exitMenu = $true }
        }
    }
}

# Variables de caché a nivel de script para el estado de los paquetes.
# Esto evita tener que consultar a choco/winget cada vez que se redibuja el menú,
# mejorando drásticamente el rendimiento de la UI.
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
            Pause-And-Return
            return
        }
        $catalogPackages = $catalogJson.items
    } catch {
        Write-Styled -Type Error -Message "Fallo CRÍTICO al leer o procesar '${CatalogFile}': $($_.Exception.Message)"
        Pause-And-Return
        return
    }

    # Asignar dinámicamente la función de estado y el nombre de la variable de caché.
    # Esto evita un bloque if/else y hace el código más limpio.
    $statusFunctionName = "_Get-${Manager}PackageStatus"
    $cacheVariableName = "script:${Manager}StatusCache"

    $exitManagerUI = $false
    while (-not $exitManagerUI) {
        # Obtener el estado de los paquetes, usando la caché si está disponible.
        $packageStatusList = Get-Variable -Name $cacheVariableName -ErrorAction SilentlyContinue -ValueOnly
        if ($null -eq $packageStatusList) {
            Write-Styled -Type Info -Message "Obteniendo estado de los paquetes para ${Manager} (puede tardar)..."
            $packageStatusList = & (Get-Command $statusFunctionName) -CatalogPackages $catalogPackages
            # Guardar el resultado en la caché para usos futuros.
            Set-Variable -Name $cacheVariableName -Value $packageStatusList
        }

        if ($null -eq $packageStatusList) {
            Write-Styled -Type Error -Message "No se pudo continuar debido a un error al obtener el estado de los paquetes."
            Pause-And-Return
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
                Set-Variable -Name $cacheVariableName -Value $null # Invalidar caché porque se han realizado cambios.
            }
            'U' {
                $upgradableItems = $packageStatusList | Where-Object { $_.IsUpgradable }
                Show-Header -Title "Paquetes con Actualizaciones Disponibles (${Manager})"
                if ($upgradableItems.Count -gt 0) {
                    $upgradableItems | ForEach-Object { Write-Styled -Type Warn -Message "$($_.DisplayName) $($_.VersionInfo)" }
                } else {
                    Write-Styled -Type Info -Message "Todos los paquetes del catálogo están actualizados."
                }
                Pause-And-Return
            }
            'R' {
                Set-Variable -Name $cacheVariableName -Value $null # Invalidar caché para forzar la recarga.
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
        if ((Invoke-MenuPrompt -ValidChoices @('S','N') -PromptMessage "¿Desea que el script intente instalarlo ahora?") -eq 'S') {
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
        if ((Invoke-MenuPrompt -ValidChoices @('S','N') -PromptMessage "¿Desea que el script intente instalarlo ahora?") -eq 'S') {
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
                if ((Invoke-MenuPrompt -ValidChoices @('S','N') -PromptMessage "¿Está seguro de que desea continuar?") -eq 'S') {
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
