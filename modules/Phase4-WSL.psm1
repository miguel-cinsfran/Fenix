<#
.SYNOPSIS
    Módulo de Fase 4 para la instalación y administración de WSL2.
.DESCRIPTION
    Contiene la lógica para verificar los prerrequisitos de WSL2, habilitar las
    características de Windows necesarias e instalar y administrar distribuciones.
    Presenta un menú interactivo para facilitar la administración de WSL.
.NOTES
    Versión: 2.1
    Autor: miguel-cinsfran
    Revisión: Corregida la codificación de caracteres y mejorada la legibilidad.
#>

#region Internal Functions
function Enable-WindowsOptionalFeature {
    param([string]$FeatureName)
    Write-PhoenixStyledOutput -Type SubStep -Message "Habilitando la característica de Windows: '$FeatureName'..."
    $result = Invoke-NativeCommandWithOutputCapture -Executable "Dism.exe" -ArgumentList "/Online /Enable-Feature /FeatureName:$FeatureName /All /NoRestart" -Activity "Habilitando $FeatureName" -ProgressRegex '\s(\d+)\s*%'
    if (-not $result.Success) {
        throw "DISM falló al intentar habilitar '$FeatureName'. Salida: $($result.Output)"
    }
    Write-PhoenixStyledOutput -Type Warn -Message "Se ha habilitado la característica '$FeatureName'. Se requiere un reinicio para completar la instalación."
}

function Test-WslInstallation {
    Write-PhoenixStyledOutput -Type Step -Message "Verificando el estado actual de WSL..."
    $statusResult = Invoke-NativeCommandWithOutputCapture -Executable "wsl.exe" -ArgumentList "--status" -FailureStrings "no está instalado" -Activity "Verificando estado de WSL"

    if (-not $statusResult.Success) {
        Write-PhoenixStyledOutput -Type Warn -Message "WSL no está instalado o no es funcional."
        Write-PhoenixStyledOutput -Type Step -Message "Verificando prerrequisitos de Windows (VirtualMachinePlatform y Subsystem-Linux)..."

        $featuresToEnable = @()
        try {
            if ((Get-WindowsOptionalFeature -Online -FeatureName "VirtualMachinePlatform").State -ne 'Enabled') { $featuresToEnable += "VirtualMachinePlatform" }
            if ((Get-WindowsOptionalFeature -Online -FeatureName "Microsoft-Windows-Subsystem-Linux").State -ne 'Enabled') { $featuresToEnable += "Microsoft-Windows-Subsystem-Linux" }
        } catch {
            throw "No se pudieron verificar las características de Windows. Error: $($_.Exception.Message)"
        }

        if ($featuresToEnable.Count -gt 0) {
            Write-PhoenixStyledOutput -Type Warn -Message "Las siguientes características de Windows son necesarias y no están habilitadas:"
            $featuresToEnable | ForEach-Object { Write-PhoenixStyledOutput -Type Info -Message "  - $_" }
            if ((Request-MenuSelection -ValidChoices @('S','N') -PromptMessage "¿Autoriza al script a habilitar estas características?") -eq 'S') {
                foreach ($feature in $featuresToEnable) { Enable-WindowsOptionalFeature -FeatureName $feature }
                Confirm-SystemRestart
                return $false # Needs restart
            } else {
                Write-PhoenixStyledOutput -Type Error -Message "Operación cancelada. No se pueden cumplir los prerrequisitos."
                Request-Continuation
                return $false # Cannot proceed
            }
        }

        Write-PhoenixStyledOutput -Type Success -Message "Todos los prerrequisitos de Windows ya están habilitados."
        Write-PhoenixStyledOutput -Type Step -Message "Procediendo con la instalación de WSL..."
        $installResult = Invoke-NativeCommandWithOutputCapture -Executable "wsl.exe" -ArgumentList "--install" -FailureStrings "Error" -Activity "Instalando WSL" -IdleTimeoutEnabled:$false -ProgressRegex '\s(\d+)\s*%'
        if (-not $installResult.Success) {
            throw "La instalación de WSL falló. Salida: $($installResult.Output)"
        }

        Write-PhoenixStyledOutput -Type Success -Message "La instalación de WSL parece haber sido exitosa."
        Write-PhoenixStyledOutput -Type Warn -Message "Se requiere un REINICIO del sistema para finalizar la instalación de WSL."
        Confirm-SystemRestart
        return $false # Needs restart
    }

    Write-PhoenixStyledOutput -Type Success -Message "WSL ya está instalado y operativo."
    return $true # WSL is operational
}

function Disable-WindowsOptionalFeature {
    param([string]$FeatureName)
    Write-PhoenixStyledOutput -Type SubStep -Message "Deshabilitando la característica de Windows: '$FeatureName'..."
    $result = Invoke-NativeCommandWithOutputCapture -Executable "Dism.exe" -ArgumentList "/Online /Disable-Feature /FeatureName:$FeatureName /NoRestart" -Activity "Deshabilitando $FeatureName"
    if (-not $result.Success) {
        throw "DISM falló al intentar deshabilitar '$FeatureName'. Salida: $($result.Output)"
    }
    Write-PhoenixStyledOutput -Type Warn -Message "Se ha deshabilitado la característica '$FeatureName'. Se requiere un reinicio para aplicar el cambio."
}
#endregion

#region Menu Functions

function Get-AvailableWslDistro {
    Write-PhoenixStyledOutput -Type SubStep -Message "Consultando la lista de distribuciones disponibles en línea..."
    $onlineResult = Invoke-NativeCommandWithOutputCapture -Executable "wsl.exe" -ArgumentList "--list --online" -Activity "Buscando distribuciones disponibles"

    if (-not $onlineResult.Success) {
        Write-PhoenixStyledOutput -Type Error -Message "No se pudo obtener la lista de distribuciones disponibles desde Microsoft Store."
        Write-PhoenixStyledOutput -Type Log -Message "Error: $($onlineResult.Output)"
        return $null # Devolver null en caso de fallo del comando.
    }

    # Manejar casos donde el comando tiene éxito pero devuelve un mensaje de 'no hay distros'.
    if ($onlineResult.Output -match "No hay distribuciones disponibles" -or $onlineResult.Output -match "There are no distributions available") {
        # Esto no es un error, así que devolvemos un array vacío.
        return @()
    }

    # Dividir la salida en líneas y eliminar las que estén en blanco para un análisis fiable.
    $lines = $onlineResult.Output -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $distros = @()
    $parsing = $false

    foreach ($line in $lines) {
        # Empezar a analizar después de la línea de cabecera. Es más robusto que un índice fijo.
        if (-not $parsing -and $line -match "^\s*NAME\s+FRIENDLY NAME\s*") {
            $parsing = $true
            continue # Saltar la línea de cabecera.
        }

        if ($parsing) {
            # Saltar la línea separadora '---'.
            if ($line -match '^-{5,}') { continue }

            $trimmedLine = $line.Trim()

            # Detener el análisis si encontramos una línea en blanco después de haber empezado.
            if ([string]::IsNullOrWhiteSpace($trimmedLine)) { break }

            # Esta regex captura la primera palabra como NAME y el resto como FRIENDLY NAME.
            # Se usa \s+ en vez de \s{2,} para mayor robustez.
            $match = $trimmedLine -match '^([^\s]+)\s+(.*)$'
            if ($match) {
                $distros += [PSCustomObject]@{
                    Name         = $matches[1].Trim()
                    FriendlyName = $matches[2].Trim()
                }
            }
        }
    }

    if ($distros.Count -eq 0) {
        Write-PhoenixStyledOutput -Type Warn -Message "No se pudieron analizar distribuciones de la salida de WSL. Es posible que no haya distribuciones nuevas o que el formato de salida haya cambiado."
        Write-PhoenixStyledOutput -Type Log -Message "Salida recibida de WSL:"
        $onlineResult.Output.Split([System.Environment]::NewLine) | ForEach-Object { Write-PhoenixStyledOutput -Type Log -Message $_ }
    }

    return $distros
}

function Start-WslUpdateCheck {
    Show-PhoenixHeader -Title "Estado y Actualizaciones de WSL" -NoClear

    Write-PhoenixStyledOutput -Type Step -Message "Obteniendo el estado actual de WSL..."
    $statusResult = Invoke-NativeCommandWithOutputCapture -Executable "wsl.exe" -ArgumentList "--status" -Activity "Obteniendo estado de WSL"

    if ($statusResult.Success) {
        Write-Host $statusResult.Output
    } else {
        Write-PhoenixStyledOutput -Type Error -Message "No se pudo obtener el estado de WSL."
        Write-Host $statusResult.Output
        Request-Continuation
        return # Salir si no se puede obtener el estado.
    }

    Write-Host # Añadir una línea en blanco para espaciar.

    Write-PhoenixStyledOutput -Type Consent -Message "Esta opción buscará e instalará automáticamente la última versión del núcleo de WSL."
    if ((Request-MenuSelection -ValidChoices @('S','N') -PromptMessage "¿Desea buscar actualizaciones ahora?") -ne 'S') {
        Write-PhoenixStyledOutput -Type Info -Message "Operación de actualización cancelada."
        Request-Continuation
        return
    }

    Write-PhoenixStyledOutput -Type Step -Message "Buscando e instalando actualizaciones..."
    $updateResult = Invoke-NativeCommandWithOutputCapture -Executable "wsl.exe" -ArgumentList "--update" -Activity "Actualizando WSL" -IdleTimeoutEnabled:$false

    if ($updateResult.Success) {
        Write-PhoenixStyledOutput -Type Success -Message "Proceso de actualización completado."
        Write-Host $updateResult.Output
    } else {
        Write-PhoenixStyledOutput -Type Error -Message "Ocurrió un error durante el proceso de actualización."
        Write-Host $updateResult.Output
    }

    Request-Continuation
}

function Show-InstalledDistroMenu {
    while ($true) { # Bucle principal para permitir refrescar la lista.
        Show-PhoenixHeader -Title "Administrar Distribuciones Instaladas" -NoClear

        $listResult = Invoke-NativeCommandWithOutputCapture -Executable "wsl.exe" -ArgumentList "--list --verbose" -Activity "Listando distribuciones instaladas"

        if (-not $listResult.Success) {
            Write-PhoenixStyledOutput -Type Error -Message "No se pudo obtener la lista de distribuciones instaladas."
            Write-PhoenixStyledOutput -Type Log -Message "Error: $($listResult.Output)"
            Request-Continuation
            return
        }

        # Comprobar mensajes conocidos de 'no hay distros'.
        if ($listResult.Output -match "No hay distribuciones instaladas" -or $listResult.Output -match "There are no installed distributions") {
            Write-PhoenixStyledOutput -Type Warn -Message "No se encontraron distribuciones de Linux instaladas."
            Request-Continuation
            return
        }

        $lines = $listResult.Output -split '\r?\n' | Select-Object -Skip 1
        $distros = foreach ($line in $lines) {
            if ($line.Trim()) {
                # Regex más robusta que usa \S+ (cualquier cosa que no sea un espacio) para Estado y Versión.
                # Se usa \s+ en lugar de \s{2,} para ser más tolerante a cambios en el formato de la salida.
                $match = $line -match '^\s?(\*?)\s*(.+?)\s+(\S+)\s+(\S+)\s*$'
                if ($match) {
                     [PSCustomObject]@{
                        IsDefault = $matches[1] -eq '*'
                        Name      = $matches[2].Trim()
                        State     = $matches[3].Trim()
                        Version   = $matches[4].Trim()
                    }
                }
            }
        }

        if ($distros.Count -eq 0) {
            Write-PhoenixStyledOutput -Type Warn -Message "No se pudieron analizar las distribuciones instaladas."
            Request-Continuation
            return
        }

        $menuItems = @()
        foreach ($distro in $distros) {
            $description = $distro.Name
            if ($distro.IsDefault) { $description += " (Predeterminada)" }
            $menuItems += @{ Description = $description; Status = $distro.State; DistroData = $distro }
        }

        $actionOptions = @{ "V" = "Volver al menú principal" }
        $distroChoice = Show-PhoenixStandardMenu -MenuItems $menuItems -ActionOptions $actionOptions -PromptMessage "Seleccione una distribución para administrar"

        if ($distroChoice -eq 'V') { return }

        $selectedDistro = $menuItems[[int]$distroChoice - 1].DistroData

        # Submenú para la distribución seleccionada.
        $subHeader = "Administrando: $($selectedDistro.Name) (Estado: $($selectedDistro.State), Versión: $($selectedDistro.Version))"
        Show-PhoenixHeader -Title $subHeader -NoClear

        $subPrompt = @"
Seleccione una acción para '$($selectedDistro.Name)':
  1. Desinstalar (eliminará todos los datos)
  2. Establecer como distribución predeterminada
  3. Buscar actualizaciones de paquetes (requiere contraseña)
  V. Volver a la lista de distribuciones
"@
        Write-Host $subPrompt
        $subChoice = Request-MenuSelection -ValidChoices @('1', '2', '3', 'V') -PromptMessage "Acción"

        switch ($subChoice) {
            '1' { # Desinstalar
                Write-PhoenixStyledOutput -Type Consent -Message "¡ADVERTENCIA! Esto eliminará permanentemente la distribución '$($selectedDistro.Name)' y todos sus datos."
                if ((Request-MenuSelection -ValidChoices @('S','N') -PromptMessage "¿Está seguro de que desea continuar?") -eq 'S') {
                    # Se añaden comillas al nombre de la distro para manejar nombres con espacios.
                    # Se captura el resultado para verificar si la operación tuvo éxito.
                    $result = Invoke-NativeCommandWithOutputCapture -Executable "wsl.exe" -ArgumentList "--unregister `"$($selectedDistro.Name)`"" -Activity "Desinstalando $($selectedDistro.Name)"
                    if ($result.Success) {
                        Write-PhoenixStyledOutput -Type Success -Message "'$($selectedDistro.Name)' ha sido desinstalada."
                    } else {
                        Write-PhoenixStyledOutput -Type Error -Message "Falló la desinstalación de '$($selectedDistro.Name)'."
                        Write-PhoenixStyledOutput -Type Log -Message "Salida del comando:"
                        # Mostrar la salida del comando para que el usuario pueda diagnosticar el problema.
                        $result.Output | ForEach-Object { Write-PhoenixStyledOutput -Type Log -Message $_ }
                    }
                    Request-Continuation
                    break # Romper el switch para forzar un refresco de la lista.
                }
            }
            '2' { # Establecer como predeterminada
                # Se añaden comillas al nombre de la distro para manejar nombres con espacios.
                $result = Invoke-NativeCommandWithOutputCapture -Executable "wsl.exe" -ArgumentList "--set-default `"$($selectedDistro.Name)`"" -Activity "Estableciendo $($selectedDistro.Name) como predeterminada"
                if ($result.Success) {
                    Write-PhoenixStyledOutput -Type Success -Message "'$($selectedDistro.Name)' es ahora la distribución predeterminada."
                } else {
                    Write-PhoenixStyledOutput -Type Error -Message "No se pudo establecer la distribución predeterminada."
                }
                Request-Continuation
            }
            '3' { # Actualizar paquetes
                Write-PhoenixStyledOutput -Type Warn -Message "Esta acción intentará actualizar los paquetes usando 'apt'. Esto es común para distros basadas en Debian (Ubuntu, etc.)."
                Write-PhoenixStyledOutput -Type Warn -Message "Es posible que se le solicite su contraseña de sudo dentro de la terminal de WSL."
                if ((Request-MenuSelection -ValidChoices @('S','N') -PromptMessage "¿Desea continuar?") -eq 'S') {
                    Write-PhoenixStyledOutput -Type Info -Message "Lanzando el proceso de actualización para '$($selectedDistro.Name)'. Siga las instrucciones."
                    try {
                        # Se añaden comillas al nombre de la distro para el argumento -d.
                        Start-Process wsl -ArgumentList "-d `"$($selectedDistro.Name)`" -- sudo apt-get update && sudo apt-get upgrade -y" -Wait -NoNewWindow
                        Write-PhoenixStyledOutput -Type Success -Message "El proceso de actualización ha finalizado."
                    } catch {
                         Write-PhoenixStyledOutput -Type Error -Message "No se pudo iniciar el proceso de actualización. Error: $($_.Exception.Message)"
                    }
                    Request-Continuation
                }
            }
            'V' { continue } # Continuar a la siguiente iteración del bucle para mostrar la lista de distros.
        }
        if ($subChoice -eq '1') { continue } # Refrescar la lista después de desinstalar.
    }
}

function Show-AvailableDistroMenu {
    Show-PhoenixHeader -Title "Instalar Nueva Distribución" -NoClear

    # Usar la función de ayuda para obtener las distros disponibles.
    $availableDistros = Get-AvailableWslDistro

    # Manejar el posible fallo de la función de ayuda (retorno nulo).
    if ($null -eq $availableDistros) {
        # El mensaje de error ya fue impreso por la función. Solo esperar al usuario.
        Request-Continuation
        return
    }

    # Obtener la lista de distros ya instaladas para filtrarlas.
    $installedResult = Invoke-NativeCommandWithOutputCapture -Executable "wsl.exe" -ArgumentList "--list" -Activity "Listando distribuciones instaladas"
    $installedNames = @()
    if ($installedResult.Success) {
        $installedLines = $installedResult.Output -split '\r?\n' | Select-Object -Skip 1
        $installedNames = foreach ($line in $installedLines) {
            if ($line.Trim()) { ($line -replace '\(Default\)', '').Trim() }
        }
    }

    # Filtrar la lista de distros disponibles contra las ya instaladas.
    $distrosToDisplay = $availableDistros | Where-Object { $installedNames -notcontains $_.Name -and $installedNames -notcontains $_.FriendlyName }

    # Manejar el caso donde no hay nada nuevo que instalar.
    if ($distrosToDisplay.Count -eq 0) {
        Write-PhoenixStyledOutput -Type Info -Message "No hay nuevas distribuciones para instalar. Es posible que todas las disponibles ya estén instaladas."
        Request-Continuation
        return
    }

    # Mostrar el menú y manejar la instalación.
    $menuItems = @()
    foreach ($distro in $distrosToDisplay) {
        $menuItems += @{ Description = $distro.FriendlyName; DistroData = $distro }
    }

    $actionOptions = @{ "V" = "Volver al menú principal" }
    $choice = Show-PhoenixStandardMenu -Title "Seleccione una distribución para instalar" -MenuItems $menuItems -ActionOptions $actionOptions

    if ($choice -eq 'V') { return }

    $selectedDistro = $menuItems[[int]$choice - 1].DistroData

    Write-PhoenixStyledOutput -Type Consent -Message "Se instalará la distribución '$($selectedDistro.FriendlyName)'."
    if ((Request-MenuSelection -ValidChoices @('S','N') -PromptMessage "¿Desea continuar?") -eq 'S') {
        Write-PhoenixStyledOutput -Type Step -Message "Instalando $($selectedDistro.FriendlyName)... Esto puede tardar varios minutos."
        $installResult = Invoke-NativeCommandWithOutputCapture -Executable "wsl.exe" -ArgumentList "--install -d $($selectedDistro.Name)" -Activity "Instalando $($selectedDistro.Name)" -IdleTimeoutEnabled:$false -ProgressRegex '(\d+)%\s*$'

        if ($installResult.Success) {
            Write-PhoenixStyledOutput -Type Success -Message "'$($selectedDistro.FriendlyName)' se ha instalado correctamente."
        } else {
            Write-PhoenixStyledOutput -Type Error -Message "Ocurrió un error durante la instalación."
            Write-Host $installResult.Output
        }
    } else {
        Write-PhoenixStyledOutput -Type Info -Message "Instalación cancelada."
    }

    Request-Continuation
}

function Show-WslFeatureMenu {
    Show-PhoenixHeader -Title "Administrar Características de Windows para WSL" -NoClear

    $wslStatus = Invoke-NativeCommandWithOutputCapture -Executable "wsl.exe" -ArgumentList "--status" -Activity "Verificando estado de WSL"
    $isWslInstalled = $wslStatus.Success

    $features = @("VirtualMachinePlatform", "Microsoft-Windows-Subsystem-Linux")

    while ($true) {
        Show-PhoenixHeader -Title "Administrar Características de Windows para WSL" -NoClear
        Write-PhoenixStyledOutput -Type Step -Message "Estado actual de las características requeridas:"

        $featureObjects = @()
        foreach ($featureName in $features) {
            try {
                $featureState = (Get-WindowsOptionalFeature -Online -FeatureName $featureName).State
                $featureObjects += [PSCustomObject]@{ Name = $featureName; State = $featureState }
                $statusIcon = if ($featureState -eq 'Enabled') { "[✓]" } else { "[ ]" }
                $statusColor = if ($featureState -eq 'Enabled') { 'Green' } else { 'Gray' }
                Write-Host ("{0,-4} {1}" -f $statusIcon, $featureName) -ForegroundColor $statusColor
            } catch {
                Write-PhoenixStyledOutput -Type Error -Message "No se pudo obtener el estado de la característica '$featureName'."
                $featureObjects += [PSCustomObject]@{ Name = $featureName; State = "Error" }
            }
        }
        Write-Host ""

        if ($isWslInstalled) {
            Write-PhoenixStyledOutput -Type Warn -Message "WSL está instalado. Para evitar problemas, las características no se pueden modificar desde este menú."
            Write-PhoenixStyledOutput -Type Warn -Message "Para deshabilitarlas, primero debe desinstalar WSL usando la opción del menú principal."
            Request-Continuation
            return
        }

        Write-PhoenixStyledOutput -Type Consent -Message "WSL no está instalado. Puede habilitar o deshabilitar estas características."
        $prompt = @"
Seleccione una opción:
  1. Habilitar 'VirtualMachinePlatform'
  2. Deshabilitar 'VirtualMachinePlatform'
  3. Habilitar 'Microsoft-Windows-Subsystem-Linux'
  4. Deshabilitar 'Microsoft-Windows-Subsystem-Linux'
  V. Volver al menú principal
"@
        Write-Host $prompt
        $choice = Request-MenuSelection -ValidChoices @('1','2','3','4','V') -PromptMessage "Acción"

        $needsRestart = $false
        switch ($choice) {
            '1' { Enable-WindowsOptionalFeature -FeatureName "VirtualMachinePlatform"; $needsRestart = $true }
            '2' { Disable-WindowsOptionalFeature -FeatureName "VirtualMachinePlatform"; $needsRestart = $true }
            '3' { Enable-WindowsOptionalFeature -FeatureName "Microsoft-Windows-Subsystem-Linux"; $needsRestart = $true }
            '4' { Disable-WindowsOptionalFeature -FeatureName "Microsoft-Windows-Subsystem-Linux"; $needsRestart = $true }
            'V' { return }
        }

        if ($needsRestart) {
            Confirm-SystemRestart
            Write-PhoenixStyledOutput -Type Info -Message "El estado actualizado se reflejará después de un reinicio."
            Request-Continuation
        }
    }
}

function Start-WslUninstall {
    Show-PhoenixHeader -Title "Desinstalar WSL" -NoClear

    Write-PhoenixStyledOutput -Type Error -Message "¡¡¡ADVERTENCIA MUY IMPORTANTE!!!"
    Write-PhoenixStyledOutput -Type Warn -Message "Esta operación es destructiva y no se puede deshacer."
    Write-PhoenixStyledOutput -Type Warn -Message "Se procederá a desregistrar TODAS las distribuciones de WSL instaladas."
    Write-PhoenixStyledOutput -Type Warn -Message "Esto significa que se eliminarán permanentemente todos los datos, archivos y configuraciones dentro de esas distribuciones."
    Write-Host ""

    if ((Request-MenuSelection -ValidChoices @('S','N') -PromptMessage "¿Entiende las consecuencias y desea continuar?") -ne 'S') {
        Write-PhoenixStyledOutput -Type Info -Message "Operación de desinstalación cancelada."
        Request-Continuation
        return
    }

    Write-PhoenixStyledOutput -Type Consent -Message "Para confirmar esta acción, por favor escriba la palabra 'DESINSTALAR' y presione Enter."
    $confirmation = Read-Host
    if ($confirmation.Trim().ToUpper() -ne 'DESINSTALAR') {
        Write-PhoenixStyledOutput -Type Info -Message "La confirmación no coincide. Operación de desinstalación cancelada."
        Request-Continuation
        return
    }

    Write-PhoenixStyledOutput -Type Step -Message "Procediendo con la desinstalación de las distribuciones de WSL..."

    $listResult = Invoke-NativeCommandWithOutputCapture -Executable "wsl.exe" -ArgumentList "--list" -Activity "Listando distribuciones para desinstalar"
    if ($listResult.Success -and $listResult.Output -notmatch "No hay distribuciones instaladas") {
        $lines = $listResult.Output -split '\r?\n' | Select-Object -Skip 1
        $distrosToUninstall = foreach ($line in $lines) {
            if ($line.Trim()) {
                ($line -replace '\(Default\)', '').Trim()
            }
        }

        foreach ($distro in $distrosToUninstall) {
            Write-PhoenixStyledOutput -Type SubStep -Message "Desregistrando '$distro'..."
            Invoke-NativeCommandWithOutputCapture -Executable "wsl.exe" -ArgumentList "--unregister `"$distro`"" -Activity "Desregistrando $distro"
        }
        Write-PhoenixStyledOutput -Type Success -Message "Todas las distribuciones han sido desregistradas."
    } else {
        Write-PhoenixStyledOutput -Type Info -Message "No se encontraron distribuciones instaladas para desregistrar."
    }

    Write-PhoenixStyledOutput -Type Step -Message "Apagando el subsistema de WSL..."
    Invoke-NativeCommandWithOutputCapture -Executable "wsl.exe" -ArgumentList "--shutdown" -Activity "Apagando WSL"

    Write-PhoenixStyledOutput -Type Success -Message "El proceso de limpieza de distribuciones ha finalizado."
    Write-Host ""
    Write-PhoenixStyledOutput -Type Step -Message "PASO FINAL REQUERIDO MANUALMENTE:"
    Write-PhoenixStyledOutput -Type Info -Message "Para completar la desinstalación, debe desinstalar la aplicación 'Subsistema de Windows para Linux'."
    Write-PhoenixStyledOutput -Type Info -Message "1. Abra el menú Inicio y busque 'Aplicaciones y características'."
    Write-PhoenixStyledOutput -Type Info -Message "2. En la lista de aplicaciones, busque 'Subsistema de Windows para Linux'."
    Write-PhoenixStyledOutput -Type Info -Message "3. Haga clic en él y seleccione 'Desinstalar'."
    Write-PhoenixStyledOutput -Type Warn -Message "Es posible que se requiera un reinicio después de este paso."
    Write-Host ""
    Write-PhoenixStyledOutput -Type Info -Message "Si desea también deshabilitar las características de Windows subyacentes, puede usar la opción 'Administrar características' en el menú anterior DESPUÉS de reiniciar."

    Request-Continuation
}
#endregion


function Invoke-WslPhase {
    Show-PhoenixHeader -Title "FASE 4: Administración de WSL2"

    try {
        $wslOperational = Test-WslInstallation
        if (-not $wslOperational) {
            Write-PhoenixStyledOutput -Type Info -Message "La configuración de WSL no está completa o requiere un reinicio. Saliendo del módulo de WSL."
            Request-Continuation
            return
        }

        # Bucle del Menú Principal
        while ($true) {
            Show-PhoenixHeader -Title "Administración de WSL" -NoClear

            $menuItems = @(
                @{ Description = "Ver estado y buscar actualizaciones de WSL" },
                @{ Description = "Administrar distribuciones instaladas" },
                @{ Description = "Instalar una nueva distribución" },
                @{ Description = "Administrar características de Windows para WSL" },
                @{ Description = "Desinstalar WSL" }
            )

            $actionOptions = @{
                "S" = "Salir"
            }

            $choices = Show-PhoenixStandardMenu -Title "Menú Principal de WSL" -MenuItems $menuItems -ActionOptions $actionOptions -PromptMessage "Seleccione una tarea"
            if ($choices.Count -eq 0) { continue }

            foreach ($choice in $choices) {
                switch ($choice) {
                    "1" { Start-WslUpdateCheck }
                    "2" { Show-InstalledDistroMenu }
                    "3" { Show-AvailableDistroMenu }
                    "4" { Show-WslFeatureMenu }
                    "5" { Start-WslUninstall }
                    "S" { Write-PhoenixStyledOutput -Type Info -Message "Saliendo del menú de WSL."; return }
                }
            }
        }
    } catch {
        Write-PhoenixStyledOutput -Type Error -Message "Error fatal en el módulo de WSL: $($_.Exception.Message)"
        Request-Continuation
    }
}

# Exportar únicamente las funciones destinadas al consumo público para evitar la
# exposición de helpers internos y cumplir con las mejores prácticas de modularización.
Export-ModuleMember -Function Invoke-WslPhase
