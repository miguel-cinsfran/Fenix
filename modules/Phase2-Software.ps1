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
                if ($jobOutput -match "not found|was not found") {
                    $jobFailed = $true
                    $failureReason = "Chocolatey no pudo encontrar el paquete."
                }
            }
            elseif ($Manager -eq 'Winget') {
                if ($jobOutput -match "No se encontró ningún paquete|No package found") {
                    $jobFailed = $true
                    $failureReason = "Winget no pudo encontrar el paquete."
                }
            }
        }

        if ($jobFailed) {
            $state.FatalErrorOccurred = $true
            Write-Styled -Type Error -Message "Falló la instalación de $PackageName. Razón: $failureReason"
            Write-Styled -Type Log -Message "--- INICIO DE EVIDENCIA DE ERROR CRUDO PARA '$PackageName' ---"
            $jobOutput | ForEach-Object { Write-Styled -Type Log -Message $_ }
            Write-Styled -Type Log -Message "--- FIN DE EVIDENCIA DE ERROR CRUDO ---"
        } else {
            Write-Styled -Type Success -Message "Instalación de $PackageName finalizada."
        }
    } finally {
        Remove-Job $job -Force
    }
}

# Nueva función para manejar la UI de un gestor de paquetes específico
function Invoke-SoftwareManagerUI {
    param(
        [string]$Manager,
        [string]$CatalogFile,
        [PSCustomObject]$state
    )

    try {
        $packages = (Get-Content -Raw -Path $CatalogFile -Encoding UTF8 | ConvertFrom-Json).items
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
        Write-Styled -Type Info -Message "Obteniendo estado de los paquetes... (Esto puede tardar unos segundos)"

        # Recopilar información de estado para cada paquete
        $packageStatusList = foreach ($pkg in $packages) {
            $status = "No Instalado"
            $versionInfo = ""
            $isUpgradable = $false

            if ($Manager -eq 'Chocolatey') {
                $installed = choco list --limit-output --exact $pkg.installId
                if ($installed) {
                    $version = ($installed -split '\|')[1].Trim()
                    $status = "Instalado"
                    $versionInfo = "(v$version)"
                    $outdated = choco outdated --limit-output --exact $pkg.installId
                    if ($outdated) {
                        $availableVersion = ($outdated -split '\|')[2].Trim()
                        $status = "Actualización Disponible"
                        $versionInfo = "(v$version -> v$availableVersion)"
                        $isUpgradable = $true
                    }
                }
            }
            elseif ($Manager -eq 'Winget') {
                $wingetListArgs = @("list", "--disable-interactivity", "--accept-source-agreements")
                if ($pkg.checkName) { $wingetListArgs += "--name", $pkg.checkName } else { $wingetListArgs += "--id", $pkg.installId }
                if ($pkg.source) { $wingetListArgs += "--source", $pkg.source }
                $checkResult = & winget $wingetListArgs

                $installedVersion = $null
                foreach ($line in $checkResult) { if ($line -match "^(.+?)\s+($([regex]::Escape($pkg.installId)))\s+([^\s]+)") { $installedVersion = $matches[3]; break } }

                if ($installedVersion) {
                    $status = "Instalado"
                    $versionInfo = "(v$installedVersion)"
                    # Winget upgrade --dry-run no es fiable, así que lo simulamos
                    $upgradeArgs = @("upgrade", "--id", $pkg.installId, "--accept-package-agreements", "--include-unknown")
                    if ($pkg.source) { $upgradeArgs += "--source", $pkg.source }
                    $upgradeResult = & winget $upgradeArgs
                    if ($upgradeResult -match "Se encontró un paquete que coincide con la entrada") {
                        $status = "Actualización Disponible"
                        $isUpgradable = $true
                    }
                }
            }

            [PSCustomObject]@{
                DisplayName  = if ($pkg.name) { $pkg.name } else { $pkg.installId }
                Package      = $pkg
                Status       = $status
                VersionInfo  = $versionInfo
                IsUpgradable = $isUpgradable
            }
        }

        # Mostrar la lista de paquetes
        for ($i = 0; $i -lt $packageStatusList.Count; $i++) {
            $item = $packageStatusList[$i]
            $color = @{ "Instalado" = "Green"; "No Instalado" = "DarkGray"; "Actualización Disponible" = "Yellow" }[$item.Status]
            Write-Host ("[{0,2}] {1,-35} " -f ($i + 1), $item.DisplayName) -NoNewline
            Write-Host ("[{0}]" -f $item.Status.ToUpper()) -F $color -NoNewline
            Write-Host " $($item.VersionInfo)"
        }

        # Menú de acciones
        Write-Host
        Write-Styled -Type Consent -Message "[A] Instalar/Actualizar TODO lo pendiente"
        Write-Styled -Type Consent -Message "[0] Volver al menú anterior"
        Write-Host

        $numericChoices = 1..$packageStatusList.Count
        $validChoices = @($numericChoices) + @('A', '0')
        $choice = Invoke-MenuPrompt -ValidChoices $validChoices -PromptMessage "Seleccione un paquete para instalar/actualizar, (A) para todos, o (0) para volver"

        if ($choice -eq '0') {
            $exitManagerUI = $true
            continue
        }

        $packagesToProcess = @()
        if ($choice -eq 'A') {
            $packagesToProcess = $packageStatusList | Where-Object { $_.Status -ne 'Instalado' }
            if ($packagesToProcess.Count -eq 0) {
                Write-Styled -Type Warn -Message "No hay paquetes pendientes para instalar o actualizar."
                Start-Sleep -Seconds 2
                continue
            }
        } else {
            $selectedItem = $packageStatusList[[int]$choice - 1]
            if ($selectedItem.Status -eq 'Instalado') {
                Write-Styled -Type Warn -Message "El paquete seleccionado ya está instalado y actualizado."
                Start-Sleep -Seconds 2
                continue
            }
            $packagesToProcess = @($selectedItem)
        }

        foreach ($item in $packagesToProcess) {
            if ($state.FatalErrorOccurred) { Write-Styled -Type Error -Message "Abortando debido a error previo."; break }

            $pkg = $item.Package
            $command = if ($item.IsUpgradable) { "upgrade" } else { "install" }

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

            if ($pkg.PSObject.Properties.Name -contains 'postInstallNotes' -and -not [string]::IsNullOrWhiteSpace($pkg.postInstallNotes)) {
                $state.ManualActions.Add($pkg.postInstallNotes)
            }
        }

        # Pausar solo si se realizó una acción y no hubo errores.
        if ($packagesToProcess.Count -gt 0 -and -not $state.FatalErrorOccurred) {
            Pause-And-Return
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

        $choice = Invoke-MenuPrompt -ValidChoices @('1', '2', '0')

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

    # El estado de 'SoftwareInstalled' se podría manejar de forma más granular,
    # pero por ahora lo dejamos como estaba.
    if (-not $state.FatalErrorOccurred) { $state.SoftwareInstalled = $true }
    return $state
}