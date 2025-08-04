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

function Install-SoftwareCatalog {
    param([string]$Manager, [string]$CatalogFile, [PSCustomObject]$state)
    if ($state.FatalErrorOccurred) { return }
    Write-Styled -Type Step -Message "[Procesando Catálogo de $Manager]"
    try {
        $packages = (Get-Content -Raw -Path $CatalogFile -Encoding UTF8 | ConvertFrom-Json).items
    } catch {
        Write-Styled -Type Error -Message "Fallo CRÍTICO al procesar '$CatalogFile'."
        Write-Styled -Type Consent -Message "Esto es casi siempre causado por un error de sintaxis en el archivo JSON, como una coma (,) faltante o una llave ({}) mal cerrada."
        Write-Styled -Type Log -Message "Error técnico original: $($_.Exception.Message)"
        $state.FatalErrorOccurred = $true
        return
    }

    foreach ($pkg in $packages) {
        if ($state.FatalErrorOccurred) { Write-Styled -Type Error -Message "Abortando debido a error previo."; break }
        $displayName = if ($pkg.name) { $pkg.name } else { $pkg.installId }
        Write-Styled -Type SubStep -Message "Verificando $displayName..."

        if ($Manager -eq 'Chocolatey') {
            $checkResult = choco list --limit-output --exact $pkg.installId
            if ($checkResult) { $version = ($checkResult -split '\|')[1].Trim(); Write-Styled -Type Warn -Message "Ya instalado (Versión: $version), omitiendo."; continue }
            $chocoArgs = @("install", $pkg.installId, "-y", "--no-progress")
            if ($pkg.PSObject.Properties.Name -contains 'special_params') { $chocoArgs += "--params='$($pkg.special_params)'" }
            Execute-InstallJob -PackageName $displayName -InstallBlock { & choco $using:chocoArgs } -state $state -Manager 'Chocolatey'
            if ($pkg.installId -eq 'postgresql15') { $state.ManualActions.Add("Recordatorio: La contraseña para PostgreSQL se estableció como '1122'. Cámbiela.") }
        }
        elseif ($Manager -eq 'Winget') {
            $wingetListArgs = @("list", "--disable-interactivity")
            if ($pkg.checkName) { $wingetListArgs += "--name", $pkg.checkName; $idToMatchInRegex = $pkg.installId } 
            else { $wingetListArgs += "--id", $pkg.installId; $idToMatchInRegex = $pkg.installId }
            if ($pkg.source) { $wingetListArgs += "--source", $pkg.source }
            $checkResult = & winget $wingetListArgs
            $installedVersion = $null
            foreach ($line in $checkResult) { if ($line -match "^(.+?)\s+($([regex]::Escape($idToMatchInRegex)))\s+([^\s]+)") { $installedVersion = $matches[3]; break } }
            if ($installedVersion) { Write-Styled -Type Warn -Message "Ya instalado (Versión: $installedVersion), omitiendo."; continue }
            $wingetInstallArgs = @("install", "--id", $pkg.installId, "--silent", "--disable-interactivity", "--accept-package-agreements", "--accept-source-agreements")
            if ($pkg.source) { $wingetInstallArgs += "--source", $pkg.source }
            Execute-InstallJob -PackageName $displayName -InstallBlock { & winget $using:wingetInstallArgs } -state $state -Manager 'Winget'
            if ($pkg.installId -eq 'CoreyButler.NVMforWindows') { $state.ManualActions.Add("Para NVM: Abra un NUEVO terminal y ejecute 'nvm install lts' y 'nvm use lts'.") }
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

    $subMenuOptions = @(
        [PSCustomObject]@{
            Description = "Instalar Catálogo de Chocolatey"
            Action = { param($s) Install-SoftwareCatalog -Manager 'Chocolatey' -CatalogFile $chocoCatalog -state $s }
        },
        [PSCustomObject]@{
            Description = "Instalar Catálogo de Winget"
            Action = { param($s) Install-SoftwareCatalog -Manager 'Winget' -CatalogFile $wingetCatalog -state $s }
        },
        [PSCustomObject]@{
            Description = "Instalar TODOS los catálogos"
            Action = { 
                param($s) 
                Install-SoftwareCatalog -Manager 'Chocolatey' -CatalogFile $chocoCatalog -state $s
                if (-not $s.FatalErrorOccurred) {
                    Install-SoftwareCatalog -Manager 'Winget' -CatalogFile $wingetCatalog -state $s
                }
            }
        }
    )

    $exitSubMenu = $false
    while (-not $exitSubMenu) {
        Show-Header -Title "FASE 2: Instalación de Software"
        for ($i = 0; $i -lt $subMenuOptions.Count; $i++) {
            Write-Styled -Type Step -Message "[$($i+1)] $($subMenuOptions[$i].Description)"
        }
        Write-Styled -Type Step -Message "[0] Volver al Menú Principal"
        Write-Host

        if ($state.FatalErrorOccurred) {
            Write-Styled -Type Error -Message "Un error fatal ocurrió durante la instalación. No se pueden iniciar nuevas tareas."
            Write-Styled -Type Consent -Message "Presione 0 para volver."
        }
        
        $numericChoices = 1..$subMenuOptions.Count
        $validChoices = @($numericChoices) + @('0')
        $choice = Invoke-MenuPrompt -ValidChoices $validChoices

        if ($choice -eq '0') {
            $exitSubMenu = $true
            continue
        }

        $chosenIndex = [int]$choice - 1
        $chosenOption = $subMenuOptions[$chosenIndex]
        & $chosenOption.Action -s $state
        
        Pause-And-Return -Message "Presione Enter para volver al submenú..."
    }
    if (-not $state.FatalErrorOccurred) { $state.SoftwareInstalled = $true }
    return $state
}