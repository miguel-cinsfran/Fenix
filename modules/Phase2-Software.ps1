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

function Invalidate-PackageCache {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Chocolatey', 'Winget')]
        [string]$Manager
    )
    Write-Styled -Type SubStep -Message "Invalidando caché para ${Manager}."
    if ($Manager -eq 'Chocolatey') {
        $script:chocolateyStatusCache = $null
    } else { # Winget
        $script:wingetStatusCache = $null
    }
}

function _Invoke-ProcessPendingPackages {
    param(
        [string]$Manager,
        [array]$PackageStatusList,
        [psobject]$Module
    )
    $packagesToProcess = $PackageStatusList | Where-Object { $_.Status -eq 'No Instalado' -or $_.IsUpgradable }
    if ($packagesToProcess.Count -gt 0) {
        Write-Styled -Type Info -Message "Procesando $($packagesToProcess.Count) paquetes para ${Manager}..."
        try {
            foreach ($item in $packagesToProcess) {
                if ($item.IsUpgradable) {
                    & $Module.Update-Package -Item $item
                } else {
                    & $Module.Install-Package -Item $item
                }
            }
            Invalidate-PackageCache -Manager $Manager
        } catch {
            Write-Styled -Type Error -Message "Ocurrió un error durante el procesamiento masivo para ${Manager}."
            Pause-And-Return
        }
    } else {
        Write-Styled -Type Info -Message "No hay paquetes para instalar o actualizar para ${Manager}."
        Start-Sleep -Seconds 2
    }
}

#endregion

#region Menus

function _Get-PackageMenuActions {
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

function _Invoke-SinglePackageMenu {
    param(
        [string]$Manager,
        [psobject]$Item,
        [psobject]$Module
    )
    $exitMenu = $false
    while (-not $exitMenu) {
        Show-Header -Title "Gestionando: $($Item.DisplayName)" -NoClear
        Write-Styled -Type Info -Message "Estado: $($Item.Status) $($Item.VersionInfo)"

        $menuActions = _Get-PackageMenuActions -Item $Item
        $menuOptions = [ordered]@{}
        $menuActions | ForEach-Object { $menuOptions[$_.Action] = $_.Label }

        Write-Styled -Type Title -Message "Acciones Disponibles:"
        foreach ($key in $menuOptions.Keys) {
            Write-Styled -Type Consent -Message "[$key] $($menuOptions[$key])"
        }

        $promptChoices = Invoke-MenuPrompt -ValidChoices ($menuOptions.Keys | ForEach-Object { "$_" })
        if ($promptChoices.Count -eq 0) { continue }
        $choice = $promptChoices[0]

        try {
            switch ($choice) {
                'I' {
                    & $Module.Install-Package -Item $Item
                    Invalidate-PackageCache -Manager $Manager
                    $exitMenu = $true
                }
                'A' {
                    & $Module.Update-Package -Item $Item
                    Invalidate-PackageCache -Manager $Manager
                    $exitMenu = $true
                }
                'D' {
                    $confirmChoice = (Invoke-MenuPrompt -ValidChoices @('S','N') -PromptMessage "¿Está seguro de que desea desinstalar $($Item.DisplayName)?")
                    if ($confirmChoice[0] -eq 'S') {
                        & $Module.Uninstall-Package -Item $Item
                        Invalidate-PackageCache -Manager $Manager
                    }
                    $exitMenu = $true
                }
                '0' { $exitMenu = $true }
            }
        } catch {
            Write-Styled -Type Error -Message "La operación del paquete falló: $($_.Exception.Message)"
            Pause-And-Return
        }
    }
}

# Variables de caché a nivel de script para el estado de los paquetes.
$script:chocolateyStatusCache = $null
$script:wingetStatusCache = $null

function Invoke-SoftwareManagerUI {
    param(
        [string]$Manager,
        [string]$CatalogFile,
        [psobject]$Module
    )

    try {
        $catalogContent = Get-Content -Raw -Path $CatalogFile -Encoding UTF8
        $catalogJson = $catalogContent | ConvertFrom-Json

        if ($null -eq $catalogJson.'$schema') {
            Write-Styled -Type Warn -Message "El catálogo '$CatalogFile' no especifica un '$schema'. Se omitirá la validación."
        } else {
            $catalogDir = Split-Path -Path $CatalogFile -Parent
            $schemaPath = Join-Path -Path $catalogDir -ChildPath $catalogJson.'$schema'

            if (-not (Test-Path $schemaPath)) {
                Write-Styled -Type Error -Message "No se encontró el fichero de esquema '$schemaPath' definido en '$CatalogFile'."
                Pause-And-Return; return
            }

            if (-not (Test-Json -Path $CatalogFile -SchemaPath $schemaPath)) {
                Write-Styled -Type Error -Message "El fichero de catálogo '$CatalogFile' no cumple con su esquema."
                Write-Styled -Type Log -Message "Error de validación: $($_.Exception.Message)"
                Pause-And-Return; return
            }
            Write-Styled -Type Success -Message "El catálogo '$((Split-Path $CatalogFile -Leaf))' fue validado con éxito."
        }

        # La validación manual sigue siendo útil para semántica que JSON Schema no puede cubrir.
        if (-not (Test-SoftwareCatalog -CatalogData $catalogJson -CatalogFileName (Split-Path $CatalogFile -Leaf))) {
            Pause-And-Return; return
        }
        $catalogPackages = $catalogJson.items
    } catch {
        Write-Styled -Type Error -Message "Fallo CRÍTICO al leer o procesar '${CatalogFile}': $($_.Exception.Message)"
        Pause-And-Return; return
    }

    $cacheVariableName = "script:${Manager}StatusCache"

    $exitManagerUI = $false
    while (-not $exitManagerUI) {
        $packageStatusList = Get-Variable -Name $cacheVariableName -ErrorAction SilentlyContinue -ValueOnly
        if ($null -eq $packageStatusList) {
            Write-Styled -Type Info -Message "Obteniendo estado de los paquetes para ${Manager} (puede tardar)..."
            $packageStatusList = & $Module.Get-PackageStatus -CatalogPackages $catalogPackages
            Set-Variable -Name $cacheVariableName -Value $packageStatusList
        }

        if ($null -eq $packageStatusList) {
            Write-Styled -Type Error -Message "No se pudo continuar debido a un error al obtener el estado de los paquetes."
            Pause-And-Return; return
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
        $choices = Invoke-StandardMenu -Title $title -MenuItems $menuItems -ActionOptions $actionOptions

        if ($choices.Count -eq 0) { continue }

        # Procesar primero las acciones de una sola letra, ya que son mutuamente excluyentes
        if ($choices -contains '0') { $exitManagerUI = $true; continue }
        if ($choices -contains 'R') { Invalidate-PackageCache -Manager $Manager; continue }
        if ($choices -contains 'A') {
            _Invoke-ProcessPendingPackages -Manager $Manager -PackageStatusList $packageStatusList -Module $Module
            continue
        }
        if ($choices -contains 'U') {
            $upgradableItems = $packageStatusList | Where-Object { $_.IsUpgradable }
            Show-Header -Title "Paquetes con Actualizaciones Disponibles (${Manager})"
            if ($upgradableItems.Count -gt 0) {
                $upgradableItems | ForEach-Object { Write-Styled -Type Warn -Message "$($_.DisplayName) $($_.VersionInfo)" }
            } else {
                Write-Styled -Type Info -Message "Todos los paquetes del catálogo están actualizados."
            }
            Pause-And-Return
            continue
        }

        # Si no hubo acciones de una sola letra, procesar las selecciones numéricas.
        $numericActions = $choices | ForEach-Object { [int]$_ } | Sort-Object
        foreach ($choice in $numericActions) {
            $packageIndex = $choice - 1
            if ($packageIndex -ge 0 -and $packageIndex -lt $packageStatusList.Count) {
                $selectedItem = $packageStatusList[$packageIndex]
                _Invoke-SinglePackageMenu -Manager $Manager -Item $selectedItem -Module $Module
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

function Invoke-Phase2_SoftwareMenu {
    param([string]$CatalogPath)

    # Cargar los módulos de los gestores de paquetes
    $managerModules = @{}
    try {
        $managerModules['Chocolatey'] = Import-Module (Join-Path $PSScriptRoot "package_managers/chocolatey.psm1") -PassThru
        $managerModules['Winget'] = Import-Module (Join-Path $PSScriptRoot "package_managers/winget.psm1") -PassThru
    } catch {
        Write-Styled -Type Error -Message "No se pudo cargar un módulo de gestor de paquetes: $($_.Exception.Message)"
        Pause-And-Return; return
    }

    $chocoCatalogFile = Join-Path $CatalogPath "chocolatey_catalog.json"
    $wingetCatalogFile = Join-Path $CatalogPath "winget_catalog.json"
    if (-not (Test-Path $chocoCatalogFile) -or -not (Test-Path $wingetCatalogFile)) {
        Write-Styled -Type Error -Message "No se encontraron los archivos de catálogo en '${CatalogPath}'."
        Pause-And-Return; return
    }

    $exitSubMenu = $false
    while (-not $exitSubMenu) {
        Show-Header -Title "FASE 2: Instalación de Software"
        Write-Styled -Type Step -Message "[1] Administrar paquetes de Chocolatey"
        Write-Styled -Type Step -Message "[2] Administrar paquetes de Winget"
        Write-Styled -Type Step -Message "[3] Instalar TODOS los paquetes de ambos catálogos"
        Write-Styled -Type Step -Message "[0] Volver al Menú Principal"
        Write-Host

        $choices = Invoke-MenuPrompt -ValidChoices @('1', '2', '3', '0')
        if ($choices.Count -eq 0) { continue }
        $choice = $choices[0] # Solo tiene sentido una opción a la vez en este menú.

        switch ($choice) {
            '1' {
                Invoke-SoftwareManagerUI -Manager 'Chocolatey' -CatalogFile $chocoCatalogFile -Module $managerModules['Chocolatey']
            }
            '2' {
                Invoke-SoftwareManagerUI -Manager 'Winget' -CatalogFile $wingetCatalogFile -Module $managerModules['Winget']
            }
            '3' {
                if ((Invoke-MenuPrompt -ValidChoices @('S','N') -PromptMessage "¿Instalar todos los paquetes de AMBOS catálogos?") -eq 'S') {
                    foreach ($managerName in $managerModules.Keys) {
                        $managerModule = $managerModules[$managerName]
                        $catalogFile = if ($managerName -eq 'Chocolatey') { $chocoCatalogFile } else { $wingetCatalogFile }

                        Show-Header -Title "Instalación Masiva: ${managerName}"
                        $catalogPackages = (Get-Content -Raw -Path $catalogFile -Encoding UTF8 | ConvertFrom-Json).items
                        $packageStatusList = & $managerModule.Get-PackageStatus -CatalogPackages $catalogPackages

                        _Invoke-ProcessPendingPackages -Manager $managerName -PackageStatusList $packageStatusList -Module $managerModule
                    }
                    Invalidate-PackageCache -Manager 'Chocolatey'
                    Invalidate-PackageCache -Manager 'Winget'
                    Pause-And-Return
                }
            }
            '0' { $exitSubMenu = $true }
        }
    }
}
#endregion
