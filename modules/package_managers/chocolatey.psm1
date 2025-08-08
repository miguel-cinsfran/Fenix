#
# Fénix Provisioning Engine - Module for managing Chocolatey packages
#

function Invoke-ChocolateyCli {
    param(
        [string]$PackageName,
        [string]$ArgumentList
    )

    $result = Invoke-NativeCommandWithOutputCapture -Executable "choco" -ArgumentList $ArgumentList -FailureStrings "not found", "was not found" -Activity "Ejecutando: choco ${ArgumentList}" -IdleTimeoutEnabled $false

    if (-not $result.Success) {
        Write-PhoenixStyledOutput -Type Error -Message "Falló la operación de Chocolatey para ${PackageName}."
        if ($result.Output) {
            Write-PhoenixStyledOutput -Type Log -Message "--- INICIO DE SALIDA DEL PROCESO ---"
            $result.Output | ForEach-Object { Write-PhoenixStyledOutput -Type Log -Message $_ }
            Write-PhoenixStyledOutput -Type Log -Message "--- FIN DE SALIDA DEL PROCESO ---"
        }
        throw "La operación de Chocolatey para ${PackageName} falló."
    } else {
        Write-PhoenixStyledOutput -Type Success -Message "Operación de Chocolatey para ${PackageName} finalizada."
    }
}

function Get-PackageStatus {
    [CmdletBinding()]
    param([array]$CatalogPackages)

    Write-PhoenixStyledOutput -Type Info -Message "Consultando paquetes de Chocolatey instalados..."
    $installedPackages = @{}
    try {
        $listOutput = choco list --limit-output 2>&1
        if ($LASTEXITCODE -ne 0) { throw "choco list falló con código de salida $LASTEXITCODE" }
        $listOutput | ForEach-Object {
            $id, $version = $_ -split '\|'; if ($id) { $installedPackages[$id.Trim()] = $version.Trim() }
        }
    } catch {
        Write-PhoenixStyledOutput -Type Error -Message "No se pudo obtener la lista de paquetes instalados con Chocolatey: $($_.Exception.Message)"
        return $null
    }

    Write-PhoenixStyledOutput -Type Info -Message "Buscando actualizaciones para paquetes de Chocolatey..."
    $outdatedPackages = @{}
    try {
        $outdatedOutput = choco outdated --limit-output 2>&1
        if ($LASTEXITCODE -ne 0) { throw "choco outdated falló con código de salida $LASTEXITCODE" }
        $outdatedOutput | ForEach-Object {
            $id, $current, $available, $pinned = $_ -split '\|'; if ($id) { $outdatedPackages[$id.Trim()] = @{ Current = $current.Trim(); Available = $available.Trim() } }
        }
    } catch {
        Write-PhoenixStyledOutput -Type Info -Message "No se encontraron paquetes de Chocolatey para actualizar o hubo un error no crítico al verificar."
    }

    $statusCheckBlock = {
        param($Package)
        $installId = $Package.installId
        $status = "No Instalado"; $versionInfo = ""; $isUpgradable = $false

        if ($outdatedPackages.ContainsKey($installId)) {
            $status = "Actualización Disponible"
            $versionInfo = "(v$($outdatedPackages[$installId].Current) -> v$($outdatedPackages[$installId].Available))"
            $isUpgradable = $true
        }
        elseif ($installedPackages.ContainsKey($installId)) {
            $status = "Instalado"
            $versionInfo = "(v$($installedPackages[$installId]))"
        }
        return @{ Status = $status; VersionInfo = $versionInfo; IsUpgradable = $isUpgradable }
    }

    return Get-PackageStatusFromCatalog -ManagerName 'Chocolatey' -CatalogPackages $CatalogPackages -StatusCheckBlock $statusCheckBlock
}

function Install-Package {
    [CmdletBinding()]
    param([psobject]$Item)

    $pkg = $Item.Package
    $chocoArgs = @("install", $pkg.installId, "-y")
    if ($pkg.install_params) { $chocoArgs += $pkg.install_params.Split(' ') }
    if ($pkg.special_params) { $chocoArgs += "--params='$($pkg.special_params)'" }
    Invoke-ChocolateyCli -PackageName $Item.DisplayName -ArgumentList ($chocoArgs -join ' ')

    if ($pkg.PSObject.Properties.Match('postInstallConfig') -and $pkg.postInstallConfig) {
        Start-PostInstallConfiguration -Package $pkg
    }
    if ($pkg.rebootRequired) { $global:RebootIsPending = $true }
}

function Uninstall-Package {
    [CmdletBinding()]
    param([psobject]$Item)

    $pkg = $Item.Package
    $chocoArgs = @("uninstall", $pkg.installId, "-y")
    Invoke-ChocolateyCli -PackageName $Item.DisplayName -ArgumentList ($chocoArgs -join ' ')
}

function Update-Package {
    [CmdletBinding()]
    param([psobject]$Item)

    $pkg = $Item.Package
    $chocoArgs = @("upgrade", $pkg.installId, "-y")
    Invoke-ChocolateyCli -PackageName $Item.DisplayName -ArgumentList ($chocoArgs -join ' ')

    if ($pkg.PSObject.Properties.Match('postInstallConfig') -and $pkg.postInstallConfig) {
        Start-PostInstallConfiguration -Package $pkg
    }
    if ($pkg.rebootRequired) { $global:RebootIsPending = $true }
}

Export-ModuleMember -Function Get-PackageStatus, Install-Package, Uninstall-Package, Update-Package
