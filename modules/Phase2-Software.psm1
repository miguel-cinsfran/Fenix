<#
.SYNOPSIS
    Módulo de Fase 2 para la instalación de software desde manifiestos.
.DESCRIPTION
    Este módulo actúa como una capa de interfaz de usuario (UI) genérica que carga
    módulos de gestores de paquetes (como Chocolatey, Winget) y presenta un menú
    para la instalación granular o completa de software.
.NOTES
    Versión: 3.0
    Autor: miguel-cinsfran
    Revisión: Refactorizado para usar una arquitectura de módulos de gestores de paquetes.
#>

#region Package Action Helpers

function Clear-PackageStatusCache {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Chocolatey', 'Winget')]
        [string]$Manager
    )
    Write-PhoenixStyledOutput -Type SubStep -Message "Invalidando caché para ${Manager}."
    if ($Manager -eq 'Chocolatey') {
        $script:chocolateyStatusCache = $null
    } else { # Winget
        $script:wingetStatusCache = $null
    }
}

function Start-PendingPackageProcessing {
    param(
        [string]$Manager,
        [array]$PackageStatusList
    )
    $packagesToProcess = $PackageStatusList | Where-Object { $_.Status -eq 'No Instalado' -or $_.IsUpgradable }
    if ($packagesToProcess.Count -gt 0) {
        Write-PhoenixStyledOutput -Type Info -Message "Procesando $($packagesToProcess.Count) paquetes para ${Manager}..."
        try {
            foreach ($item in $packagesToProcess) {
                if ($item.IsUpgradable) {
                    if ($Manager -eq 'Chocolatey') { Update-ChocoPackage -Item $item }
                    else { Update-WingetPackage -Item $item }
                } else {
                    if ($Manager -eq 'Chocolatey') { Install-ChocoPackage -Item $item }
                    else { Install-WingetPackage -Item $item }
                }
            }
            Clear-PackageStatusCache -Manager $Manager
        } catch {
            Write-PhoenixStyledOutput -Type Error -Message "Ocurrió un error durante el procesamiento masivo para ${Manager}."
            Request-Continuation -Message "Presione Enter para continuar..."
        }
    } else {
        Write-PhoenixStyledOutput -Type Info -Message "No hay paquetes para instalar o actualizar para ${Manager}."
        Start-Sleep -Seconds 2
    }
}

#endregion

#region Menus

function Get-PackageMenuAction {
    param(
        [Parameter(Mandatory = $true)]
        $Item
    )
    $actions = [System.Collections.Generic.List[object]]::new()
    if ($Item.Status -eq 'No Instalado') {
        $actions.Add([pscustomobject]@{ Label = 'Instalar paquete'; Action = 'I' })
    }
    else {
        if ($Item.IsUpgradable) {
            $actions.Add([pscustomobject]@{ Label = 'Actualizar paquete'; Action = 'A' })
        }
        $actions.Add([pscustomobject]@{ Label = 'Desinstalar paquete'; Action = 'D' })
    }
    $actions.Add([pscustomobject]@{ Label = 'Volver'; Action = '0' })
    return $actions
}

function Install-VscodeExtensions {
    param (
        [psobject]$Package
    )

    $extensionsFile = Join-Path $PSScriptRoot "assets/configs/Microsoft.VisualStudioCode/extensions.json"
    if (-not (Test-Path $extensionsFile)) {
        Write-PhoenixStyledOutput -Type Error -Message "No se encontró el archivo de extensiones en '$extensionsFile'."
        return
    }

    $extensions = (Get-Content $extensionsFile | ConvertFrom-Json).extensions
    if (-not $extensions) {
        Write-PhoenixStyledOutput -Type Warn -Message "No se encontraron extensiones en '$extensionsFile'."
        return
    }

    Write-PhoenixStyledOutput -Type Info -Message "Buscando el ejecutable de VSCode ('code.cmd' o 'code.exe')..."
    $vscodePath = Get-Command -Name code -ErrorAction SilentlyContinue
    if (-not $vscodePath) {
        $searchPaths = @(
            (Join-Path $env:ProgramFiles "Microsoft VS Code/bin/code.cmd"),
            (Join-Path $env:LOCALAPPDATA "Programs/Microsoft VS Code/bin/code.cmd")
        )
        $vscodePath = $searchPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    }

    if (-not $vscodePath) {
        Write-PhoenixStyledOutput -Type Error -Message "No se pudo encontrar el ejecutable de VSCode. Asegúrese de que esté en el PATH o en una ubicación estándar."
        Request-Continuation
        return
    }
     Write-PhoenixStyledOutput -Type Success -Message "Ejecutable de VSCode encontrado en: $($vscodePath.Source)"

    foreach ($ext in $extensions) {
        Write-PhoenixStyledOutput -Type SubStep -Message "Instalando extensión: $ext"
        $result = Invoke-NativeCommandWithOutputCapture -Executable $vscodePath.Source -ArgumentList "--install-extension $ext" -Activity "Instalando $ext"
        if (-not $result.Success) {
            Write-PhoenixStyledOutput -Type Warn -Message "Falló la instalación de '$ext'. Puede que ya esté instalada o que haya ocurrido un error."
        }
    }
    Write-PhoenixStyledOutput -Type Success -Message "Proceso de instalación de extensiones finalizado."
    Request-Continuation
}

function Show-VscodeSubMenu {
    param(
        [string]$Manager,
        [psobject]$Item
    )

    $exitMenu = $false
    while (-not $exitMenu) {
        Show-PhoenixHeader -Title "Gestionando: $($Item.DisplayName) (Menú Especial)" -NoClear
        Write-PhoenixStyledOutput -Type Info -Message "Estado: $($Item.Status) $($Item.VersionInfo)"

        $menuOptions = [ordered]@{
            'E' = 'Instalar/Actualizar extensiones desde JSON'
            'C' = 'Forzar reaplicación de configuraciones (settings, keybindings)'
        }

        # Add standard actions based on status
        if ($Item.Status -eq 'No Instalado') {
            $menuOptions['I'] = 'Instalar paquete'
        } else {
            if ($Item.IsUpgradable) {
                $menuOptions['A'] = 'Actualizar paquete'
            }
            $menuOptions['D'] = 'Desinstalar paquete'
        }
        $menuOptions['0'] = 'Volver'


        Write-PhoenixStyledOutput -Type Title -Message "Acciones Disponibles:"
        foreach ($key in $menuOptions.Keys) {
            Write-PhoenixStyledOutput -Type Consent -Message "[$key] $($menuOptions[$key])"
        }

        $choice = Request-MenuSelection -ValidChoices ($menuOptions.Keys | ForEach-Object { "$_" }) -AllowMultipleSelections:$false
        if ([string]::IsNullOrEmpty($choice)) { continue }

        try {
            switch ($choice) {
                'I' {
                    if ($Manager -eq 'Chocolatey') { Install-ChocoPackage -Item $Item }
                    else { Install-WingetPackage -Item $Item }
                    Clear-PackageStatusCache -Manager $Manager
                    $exitMenu = $true
                }
                'A' {
                    if ($Manager -eq 'Chocolatey') { Update-ChocoPackage -Item $Item }
                    else { Update-WingetPackage -Item $Item }
                    Clear-PackageStatusCache -Manager $Manager
                    $exitMenu = $true
                }
                'D' {
                    $confirmChoice = Request-MenuSelection -ValidChoices @('S','N') -PromptMessage "¿Está seguro de que desea desinstalar $($Item.DisplayName)?" -IsYesNoPrompt
                    if ($confirmChoice -eq 'S') {
                        if ($Manager -eq 'Chocolatey') { Uninstall-ChocoPackage -Item $Item }
                        else { Uninstall-WingetPackage -Item $Item }
                        Clear-PackageStatusCache -Manager $Manager
                    }
                    $exitMenu = $true
                }
                'E' {
                    Install-VscodeExtensions -Package $Item.Package
                }
                'C' {
                    if ($Item.Status -eq 'No Instalado') {
                        Write-PhoenixStyledOutput -Type Warn -Message "VSCode no está instalado. No se pueden aplicar configuraciones."
                        Start-Sleep -Seconds 2
                    } else {
                        Write-PhoenixStyledOutput -Type Info -Message "Aplicando configuración de VSCode..."
                        Start-PostInstallConfiguration -Package $Item.Package
                    }
                }
                '0' { $exitMenu = $true }
            }
        } catch {
            Write-PhoenixStyledOutput -Type Error -Message "La operación del paquete falló: $($_.Exception.Message)"
            Request-Continuation -Message "Presione Enter para continuar..."
        }
    }
}

function Show-SinglePackageMenu {
    param(
        [string]$Manager,
        [psobject]$Item
    )

    if ($Item.Package.PSObject.Properties.Match('vscodeSubMenu') -and $Item.Package.vscodeSubMenu) {
        Show-VscodeSubMenu -Manager $Manager -Item $Item
        return
    }

    $exitMenu = $false
    while (-not $exitMenu) {
        Show-PhoenixHeader -Title "Gestionando: $($Item.DisplayName)" -NoClear
        Write-PhoenixStyledOutput -Type Info -Message "Estado: $($Item.Status) $($Item.VersionInfo)"

        $menuActions = Get-PackageMenuAction -Item $Item
        $menuOptions = [ordered]@{}
        $menuActions | ForEach-Object { $menuOptions[$_.Action] = $_.Label }

        Write-PhoenixStyledOutput -Type Title -Message "Acciones Disponibles:"
        foreach ($key in $menuOptions.Keys) {
            Write-PhoenixStyledOutput -Type Consent -Message "[$key] $($menuOptions[$key])"
        }

        $choice = Request-MenuSelection -ValidChoices ($menuOptions.Keys | ForEach-Object { "$_" }) -AllowMultipleSelections:$false
        if ([string]::IsNullOrEmpty($choice)) { continue }

        try {
            switch ($choice) {
                'I' {
                    if ($Manager -eq 'Chocolatey') { Install-ChocoPackage -Item $Item }
                    else { Install-WingetPackage -Item $Item }
                    Clear-PackageStatusCache -Manager $Manager
                    $exitMenu = $true
                }
                'A' {
                    if ($Manager -eq 'Chocolatey') { Update-ChocoPackage -Item $Item }
                    else { Update-WingetPackage -Item $Item }
                    Clear-PackageStatusCache -Manager $Manager
                    $exitMenu = $true
                }
                'D' {
                    $confirmChoice = Request-MenuSelection -ValidChoices @('S','N') -PromptMessage "¿Está seguro de que desea desinstalar $($Item.DisplayName)?" -IsYesNoPrompt
                    if ($confirmChoice -eq 'S') {
                        if ($Manager -eq 'Chocolatey') { Uninstall-ChocoPackage -Item $Item }
                        else { Uninstall-WingetPackage -Item $Item }
                        Clear-PackageStatusCache -Manager $Manager
                    }
                    $exitMenu = $true
                }
                '0' { $exitMenu = $true }
            }
        } catch {
            Write-PhoenixStyledOutput -Type Error -Message "La operación del paquete falló: $($_.Exception.Message)"
            Request-Continuation -Message "Presione Enter para continuar..."
        }
    }
}

# Variables de caché a nivel de script para el estado de los paquetes.
$script:chocolateyStatusCache = $null
$script:wingetStatusCache = $null

function Show-SoftwareManagerUI {
    param(
        [string]$Manager,
        [string]$CatalogFile
    )

    try {
        $catalogContent = Get-Content -Raw -Path $CatalogFile -Encoding UTF8
        $catalogJson = $catalogContent | ConvertFrom-Json

        # Validar que el JSON es sintácticamente correcto.
        if (-not (Test-JsonFile -Path $CatalogFile)) {
            Write-PhoenixStyledOutput -Type Error -Message "El fichero de catálogo '$CatalogFile' contiene JSON inválido."
            Request-Continuation -Message "Presione Enter para continuar..."; return
        }

        # La validación de la estructura del catálogo es crucial.
        if (-not (Test-SoftwareCatalogIntegrity -CatalogData $catalogJson -CatalogFileName (Split-Path $CatalogFile -Leaf))) {
            Request-Continuation -Message "Presione Enter para continuar..."; return
        }
        $catalogPackages = $catalogJson.items
    } catch {
        Write-PhoenixStyledOutput -Type Error -Message "Fallo CRÍTICO al leer o procesar '${CatalogFile}': $($_.Exception.Message)"
        Request-Continuation -Message "Presione Enter para continuar..."; return
    }

    $cacheVariableName = "script:${Manager}StatusCache"

    $exitManagerUI = $false
    while (-not $exitManagerUI) {
        $packageStatusList = Get-Variable -Name $cacheVariableName -ErrorAction SilentlyContinue -ValueOnly
        if ($null -eq $packageStatusList) {
            Write-PhoenixStyledOutput -Type Info -Message "Obteniendo estado de los paquetes para ${Manager} (puede tardar)..."
            if ($Manager -eq 'Chocolatey') {
                $packageStatusList = Get-ChocoPackageStatus -CatalogPackages $catalogPackages
            }
            else {
                $packageStatusList = Get-WingetPackageStatus -CatalogPackages $catalogPackages
            }
            Set-Variable -Name $cacheVariableName -Value $packageStatusList
        }

        if ($null -eq $packageStatusList) {
            Write-PhoenixStyledOutput -Type Error -Message "No se pudo continuar debido a un error al obtener el estado de los paquetes."
            Request-Continuation -Message "Presione Enter para continuar..."; return
        }

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
        $choices = Show-PhoenixStandardMenu -Title $title -MenuItems $menuItems -ActionOptions $actionOptions

        if ($choices.Count -eq 0) { continue }

        # Procesar primero las acciones de una sola letra, ya que son mutuamente excluyentes
        if ($choices -contains '0') { $exitManagerUI = $true; continue }
        if ($choices -contains 'R') { Clear-PackageStatusCache -Manager $Manager; continue }
        if ($choices -contains 'A') {
            Start-PendingPackageProcessing -Manager $Manager -PackageStatusList $packageStatusList
            continue
        }
        if ($choices -contains 'U') {
            $upgradableItems = $packageStatusList | Where-Object { $_.IsUpgradable }
            Show-PhoenixHeader -Title "Paquetes con Actualizaciones Disponibles (${Manager})"
            if ($upgradableItems.Count -gt 0) {
                $upgradableItems | ForEach-Object { Write-PhoenixStyledOutput -Type Warn -Message "$($_.DisplayName) $($_.VersionInfo)" }
            } else {
                Write-PhoenixStyledOutput -Type Info -Message "Todos los paquetes del catálogo están actualizados."
            }
            Request-Continuation -Message "Presione Enter para volver al menú..."
            continue
        }

        # Si no hubo acciones de una sola letra, procesar las selecciones numéricas.
        $numericActions = $choices | ForEach-Object { [int]$_ } | Sort-Object
        foreach ($choice in $numericActions) {
            $packageIndex = $choice - 1
            if ($packageIndex -ge 0 -and $packageIndex -lt $packageStatusList.Count) {
                $selectedItem = $packageStatusList[$packageIndex]
                Show-SinglePackageMenu -Manager $Manager -Item $selectedItem
            }
        }
    }
}

function Test-Phase2Prerequisites {
    Show-PhoenixHeader -Title "FASE 2: Verificación de Dependencias"

    $allChecksPassed = $true

    Write-PhoenixStyledOutput -Message "Verificando existencia de Chocolatey..." -NoNewline
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Write-Host " [NO ENCONTRADO]" -F $Global:Theme.Warn
        Write-PhoenixStyledOutput -Type Consent -Message "El gestor de paquetes Chocolatey no está instalado y es requerido para esta fase."
        if ((Request-MenuSelection -ValidChoices @('S','N') -PromptMessage "¿Desea que el script intente instalarlo ahora?" -IsYesNoPrompt) -eq 'S') {
            Write-PhoenixStyledOutput -Type Info -Message "Instalando Chocolatey... Esto puede tardar unos minutos."
            try {
                Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
                Write-PhoenixStyledOutput -Type Success -Message "Chocolatey se ha instalado correctamente."
            } catch {
                Write-PhoenixStyledOutput -Type Error -Message "La instalación automática de Chocolatey falló."
                $allChecksPassed = $false
            }
        } else {
            $allChecksPassed = $false
        }
    } else {
        Write-Host " [ÉXITO]" -F $Global:Theme.Success
    }

    Write-PhoenixStyledOutput -Message "Verificando existencia de Winget..." -NoNewline
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host " [NO ENCONTRADO]" -F $Global:Theme.Error
        Write-PhoenixStyledOutput -Type Error -Message "El gestor de paquetes Winget no fue encontrado. Por favor, actualice su 'App Installer' desde la Microsoft Store."
        $allChecksPassed = $false
    } else {
        Write-Host " [ÉXITO]" -F $Global:Theme.Success
        Write-PhoenixStyledOutput -Type SubStep -Message "Actualizando repositorios de Winget..."
        Invoke-NativeCommandWithOutputCapture -Executable "winget" -ArgumentList "source update" -Activity "Actualizando repositorios de Winget" | Out-Null
    }

    Write-PhoenixStyledOutput -Message "Verificando módulo de PowerShell para Winget..." -NoNewline
    if (-not (Get-Module -ListAvailable -Name Microsoft.WinGet.Client)) {
        Write-Host " [NO ENCONTRADO]" -F $Global:Theme.Warn
        Write-PhoenixStyledOutput -Type Consent -Message "El módulo de PowerShell para Winget es recomendado para una operación robusta."
        if ((Request-MenuSelection -ValidChoices @('S','N') -PromptMessage "¿Desea que el script intente instalarlo ahora?" -IsYesNoPrompt) -eq 'S') {
            Write-PhoenixStyledOutput -Type Info -Message "Instalando módulo 'Microsoft.WinGet.Client'..."
            try {
                Install-Module -Name Microsoft.WinGet.Client -Scope CurrentUser -Force -AllowClobber -AcceptLicense -ErrorAction Stop
                Write-PhoenixStyledOutput -Type Success -Message "Módulo instalado correctamente."
            } catch {
                Write-PhoenixStyledOutput -Type Error -Message "La instalación automática del módulo de Winget falló: $($_.Exception.Message)"
                Write-PhoenixStyledOutput -Type Warn -Message "El script continuará usando el método de reserva (CLI)."
                $Global:UseWingetCli = $true
            }
        } else {
            Write-PhoenixStyledOutput -Type Warn -Message "Instalación denegada. El script usará el método de reserva para Winget."
            $Global:UseWingetCli = $true
        }
    } else {
        Write-Host " [ÉXITO]" -F $Global:Theme.Success
    }

    if (-not $allChecksPassed) {
        Request-Continuation -Message "Una o más dependencias críticas no fueron satisfechas. Presione Enter para volver al menú principal."
    }
    return $allChecksPassed
}

function Invoke-SoftwareMenuPhase {
    param([string]$CatalogPath)

    if (-not (Test-Phase2Prerequisites)) {
        return
    }

    # Cargar los módulos de los gestores de paquetes con prefijos para evitar colisiones.
    try {
        Import-Module (Join-Path $PSScriptRoot "package_managers/chocolatey.psm1") -Prefix "Choco" -Force
        Import-Module (Join-Path $PSScriptRoot "package_managers/winget.psm1") -Prefix "Winget" -Force
    } catch {
        Write-PhoenixStyledOutput -Type Error -Message "No se pudo cargar un módulo de gestor de paquetes. Esto es un error fatal."
        Write-PhoenixStyledOutput -Type Log -Message "Error: $($_.Exception.Message)"
        Write-PhoenixStyledOutput -Type Log -Message "Detalles: $($_.ToString())"
        Request-Continuation -Message "Presione Enter para continuar..."; return
    }

    $chocoCatalogFile = Join-Path $CatalogPath "chocolatey_catalog.json"
    $wingetCatalogFile = Join-Path $CatalogPath "winget_catalog.json"
    if (-not (Test-Path $chocoCatalogFile) -or -not (Test-Path $wingetCatalogFile)) {
        Write-PhoenixStyledOutput -Type Error -Message "No se encontraron los archivos de catálogo en '${CatalogPath}'."
        Request-Continuation -Message "Presione Enter para continuar..."; return
    }

    $exitSubMenu = $false
    while (-not $exitSubMenu) {
        Show-PhoenixHeader -Title "FASE 2: Instalación de Software"
        Write-PhoenixStyledOutput -Type Step -Message "[1] Administrar paquetes de Chocolatey"
        Write-PhoenixStyledOutput -Type Step -Message "[2] Administrar paquetes de Winget"
        Write-PhoenixStyledOutput -Type Step -Message "[3] Instalar TODOS los paquetes de ambos catálogos"
        Write-PhoenixStyledOutput -Type Step -Message "[0] Volver al Menú Principal"
        Write-Host

        $choice = Request-MenuSelection -ValidChoices @('1', '2', '3', '0') -AllowMultipleSelections:$false
        if ([string]::IsNullOrEmpty($choice)) { continue }

        switch ($choice) {
            '1' {
                Show-SoftwareManagerUI -Manager 'Chocolatey' -CatalogFile $chocoCatalogFile
            }
            '2' {
                Show-SoftwareManagerUI -Manager 'Winget' -CatalogFile $wingetCatalogFile
            }
            '3' {
                if ((Request-MenuSelection -ValidChoices @('S','N') -PromptMessage "¿Instalar todos los paquetes de AMBOS catálogos?" -IsYesNoPrompt) -eq 'S') {
                    # Chocolatey
                    Show-PhoenixHeader -Title "Instalación Masiva: Chocolatey"
                    $chocoCatalogPackages = (Get-Content -Raw -Path $chocoCatalogFile -Encoding UTF8 | ConvertFrom-Json).items
                    $chocoStatusList = Get-ChocoPackageStatus -CatalogPackages $chocoCatalogPackages
                    Start-PendingPackageProcessing -Manager 'Chocolatey' -PackageStatusList $chocoStatusList

                    # Winget
                    Show-PhoenixHeader -Title "Instalación Masiva: Winget"
                    $wingetCatalogPackages = (Get-Content -Raw -Path $wingetCatalogFile -Encoding UTF8 | ConvertFrom-Json).items
                    $wingetStatusList = Get-WingetPackageStatus -CatalogPackages $wingetCatalogPackages
                    Start-PendingPackageProcessing -Manager 'Winget' -PackageStatusList $wingetStatusList

                    Clear-PackageStatusCache -Manager 'Chocolatey'
                    Clear-PackageStatusCache -Manager 'Winget'
                    Request-Continuation -Message "Presione Enter para volver al menú..."
                }
            }
            '0' { $exitSubMenu = $true }
        }
    }
}
#endregion

# Exportar únicamente las funciones destinadas al consumo público para evitar la
# exposición de helpers internos y cumplir con las mejores prácticas de modularización.
Export-ModuleMember -Function Invoke-SoftwareMenuPhase
