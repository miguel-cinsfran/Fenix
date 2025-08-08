# Fénix Provisioning Engine - Module for managing Winget packages

function Invoke-WingetCli {
    param(
        [string]$PackageName,
        [string]$ArgumentList
    )

    $result = Invoke-NativeCommandWithOutputCapture -Executable "winget" -ArgumentList $ArgumentList -FailureStrings "No package found" -Activity "Ejecutando: winget ${ArgumentList}" -IdleTimeoutEnabled $false

    if (-not $result.Success) {
        Write-PhoenixStyledOutput -Type Error -Message "Falló la operación de Winget para ${PackageName}."
        if ($result.Output) {
            Write-PhoenixStyledOutput -Type Log -Message "--- INICIO DE SALIDA DEL PROCESO ---"
            $result.Output | ForEach-Object { Write-PhoenixStyledOutput -Type Log -Message $_ }
            Write-PhoenixStyledOutput -Type Log -Message "--- FIN DE SALIDA DEL PROCESO ---"
        }
        throw "La operación de Winget para ${PackageName} falló."
    } else {
        Write-PhoenixStyledOutput -Type Success -Message "Operación de Winget para ${PackageName} finalizada."
    }
}

function _Parse-WingetListLine {
    param([string]$Line)
    $line = $Line.TrimEnd()
    if ([string]::IsNullOrWhiteSpace($line)) { return $null }
    $parts = $line -split '\s{2,}' | Where-Object { $_ }
    if ($parts.Count -lt 3) { return $null }
    $source = ""
    if ($parts[-1] -in @('winget', 'msstore')) {
        $source = $parts[-1]
        $parts = $parts[0..($parts.Count - 2)]
    }
    if ($parts.Count -lt 3) { return $null }
    $name = ""; $id = ""; $version = ""; $available = ""
    if ($parts.Count -ge 4) {
        $available = $parts[-1]; $version = $parts[-2]; $id = $parts[-3]
        $name = ($parts[0..($parts.Count - 4)] -join ' ').Trim()
    }
    else {
        $version = $parts[-1]; $id = $parts[-2]
        $name = ($parts[0..($parts.Count - 3)] -join ' ').Trim()
    }
    if ($available -in @('<unknown>', '<desconocido>')) { $available = "" }
    return [PSCustomObject]@{ Name = $name; Id = $id; Version = $version; Available = $available; Source = $source }
}

function _Get-PackageStatus_Cli {
    param([array]$CatalogPackages)

    Write-PhoenixStyledOutput -Type Info -Message "Consultando todos los paquetes de Winget (CLI)..."
    $listResult = Invoke-NativeCommandWithOutputCapture -Executable "winget" -ArgumentList "list --include-unknown --accept-source-agreements --disable-interactivity" -Activity "Listando todos los paquetes de Winget"
    if (-not $listResult.Success) {
        Write-PhoenixStyledOutput -Type Error -Message "El comando 'winget list' falló."; return $null
    }

    $installedById = @{}; $installedByName = @{}; $upgradableById = @{}; $upgradableByName = @{}
    $lines = $listResult.Output -split "`n"
    $dataStartIndex = 0
    while ($dataStartIndex -lt $lines.Length -and $lines[$dataStartIndex] -notmatch '^-+$') { $dataStartIndex++ }
    $dataStartIndex++
    if ($dataStartIndex -ge $lines.Length) {
        Write-PhoenixStyledOutput -Type Warn -Message "No se encontraron datos de paquetes en la salida de winget."
    }
    else {
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

    $statusCheckBlock = {
        param($Package)
        $status = "No Instalado"; $versionInfo = ""; $isUpgradable = $false
        $useNameCheck = -not [string]::IsNullOrEmpty($Package.checkName)
        $key = if ($useNameCheck) { $Package.checkName } else { $Package.installId }
        $currentInstalledMap = if ($useNameCheck) { $installedByName } else { $installedById }
        $currentUpgradableMap = if ($useNameCheck) { $upgradableByName } else { $upgradableById }

        if ($currentUpgradableMap.ContainsKey($key)) {
            $status = "Actualización Disponible"
            $versionInfo = "(v$($currentUpgradableMap[$key].Current) -> v$($currentUpgradableMap[$key].Available))"
            $isUpgradable = $true
        }
        elseif ($currentInstalledMap.ContainsKey($key)) {
            $status = "Instalado"
            $versionInfo = "(v$($currentInstalledMap[$key]))"
        }
        return @{ Status = $status; VersionInfo = $versionInfo; IsUpgradable = $isUpgradable }
    }

    return Get-PackageStatusFromCatalog -ManagerName 'Winget (CLI)' -CatalogPackages $CatalogPackages -StatusCheckBlock $statusCheckBlock
}

function Get-PackageStatus {
    [CmdletBinding()]
    param([array]$CatalogPackages)

    if ($Global:UseWingetCli -or -not (Get-Module -ListAvailable -Name Microsoft.WinGet.Client)) {
        return _Get-PackageStatus_Cli -CatalogPackages $CatalogPackages
    }
    try {
        Import-Module Microsoft.WinGet.Client -ErrorAction Stop
    } catch {
        Write-PhoenixStyledOutput -Type Error -Message "No se pudo importar el módulo 'Microsoft.WinGet.Client'."; Write-PhoenixStyledOutput -Type Warn -Message "Cambiando a método de reserva para Winget."
        return _Get-PackageStatus_Cli -CatalogPackages $CatalogPackages
    }

    Write-PhoenixStyledOutput -Type Info -Message "Consultando todos los paquetes de Winget a través del módulo..."
    $installedVersionsById = @{}; $installedVersionsByName = @{}
    $upgradableVersionsById = @{}; $upgradableVersionsByName = @{}
    try {
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
    } catch {
        Write-PhoenixStyledOutput -Type Error -Message "Fallo crítico al obtener la lista de paquetes de Winget: $($_.Exception.Message)"; return $null
    }

    $statusCheckBlock = {
        param($Package)
        $status = "No Instalado"; $versionInfo = ""; $isUpgradable = $false
        $useNameCheck = -not [string]::IsNullOrEmpty($Package.checkName)
        $key = if ($useNameCheck) { $Package.checkName } else { $Package.installId }
        $currentInstalledMap = if ($useNameCheck) { $installedVersionsByName } else { $installedVersionsById }
        $currentUpgradableMap = if ($useNameCheck) { $upgradableVersionsByName } else { $upgradableVersionsById }

        if ($currentUpgradableMap.ContainsKey($key)) {
            $status = "Actualización Disponible"
            $versionInfo = "(v$($currentUpgradableMap[$key].Current) -> v$($currentUpgradableMap[$key].Available))"
            $isUpgradable = $true
        }
        elseif ($currentInstalledMap.ContainsKey($key)) {
            $status = "Instalado"
            $versionInfo = "(v$($currentInstalledMap[$key]))"
        }
        return @{ Status = $status; VersionInfo = $versionInfo; IsUpgradable = $isUpgradable }
    }

    return Get-PackageStatusFromCatalog -ManagerName 'Winget' -CatalogPackages $CatalogPackages -StatusCheckBlock $statusCheckBlock
}

function Install-Package {
    [CmdletBinding()]
    param([psobject]$Item)

    $pkg = $Item.Package
    $wingetArgs = @("install", "--id", $pkg.installId, "--accept-package-agreements", "--accept-source-agreements")
    if ($pkg.source) { $wingetArgs += "--source", $pkg.source }
    Invoke-WingetCli -PackageName $Item.DisplayName -ArgumentList ($wingetArgs -join ' ')

    if ($pkg.PSObject.Properties.Match('postInstallConfig') -and $pkg.postInstallConfig) {
        Start-PostInstallConfiguration -Package $pkg
    }
    if ($pkg.rebootRequired) { $global:RebootIsPending = $true }
}

function Uninstall-Package {
    [CmdletBinding()]
    param([psobject]$Item)

    $pkg = $Item.Package
    $wingetArgs = @("uninstall", "--id", $pkg.installId, "--silent")
    Invoke-WingetCli -PackageName $Item.DisplayName -ArgumentList ($wingetArgs -join ' ')
}

function Update-Package {
    [CmdletBinding()]
    param([psobject]$Item)

    $pkg = $Item.Package
    # Winget 'upgrade' es funcionalmente idéntico a 'install' para un paquete ya instalado.
    $wingetArgs = @("install", "--id", $pkg.installId, "--accept-package-agreements", "--accept-source-agreements")
    Invoke-WingetCli -PackageName $Item.DisplayName -ArgumentList ($wingetArgs -join ' ')

    if ($pkg.PSObject.Properties.Match('postInstallConfig') -and $pkg.postInstallConfig) {
        Start-PostInstallConfiguration -Package $pkg
    }
    if ($pkg.rebootRequired) { $global:RebootIsPending = $true }
}

Export-ModuleMember -Function Get-PackageStatus, Install-Package, Uninstall-Package, Update-Package
