<#
.SYNOPSIS
    Módulo de Fase 6 para el saneamiento y la calidad del código.
.DESCRIPTION
    Proporciona una interfaz interactiva para analizar y corregir problemas comunes
    de formato y codificación en ficheros de texto dentro de un proyecto.
.NOTES
    Versión: 3.0
    Autor: miguel-cinsfran
#>

#region Configuración y Estado
$global:CodeQualityConfig = @{
    TargetDirectory = $PSScriptRoot
    TargetExtensions = @("*.ps1", "*.json", "*.md", "*.txt", "*.csv", "*.xml", "*.html", "*.css", "*.js")
    Rules = @{
        FixCharacterEncoding = $true
        NormalizeLineEndings = $true
        TrimTrailingWhitespace = $true
        EnsureFinalNewline = $true
    }
    LineEnding = 'CRLF' # Opciones: 'CRLF', 'LF'
}

# Diccionario de reparación de caracteres corruptos.
# Inmune a la corrupción del propio script al construir los caracteres desde sus códigos.
$global:CorruptionMap = @{
    # --- MINÃšSCULAS ---
    "$([char]195)$([char]161)" = "$([char]225)"; # á -> á
    "$([char]195)$([char]169)" = "$([char]233)"; # é -> é
    "$([char]195)$([char]173)" = "$([char]237)"; # í -> í
    "$([char]195)$([char]179)" = "$([char]243)"; # ó -> ó
    "$([char]195)$([char]186)" = "$([char]250)"; # ú -> ú
    "$([char]195)$([char]177)" = "$([char]241)"; # ñ -> ñ
    # --- MAYÃšSCULAS ---
    "$([char]195)$([char]129)" = "$([char]193)"; # Ãƒ  -> Á
    "$([char]195)$([char]137)" = "$([char]201)"; # Ãƒâ€° -> Ã‰
    "$([char]195)$([char]141)" = "$([char]205)"; # Ãƒ  -> Í
    "$([char]195)$([char]147)" = "$([char]211)"; # Ãƒâ€œ -> Ã“
    "$([char]195)$([char]154)" = "$([char]218)"; # ÃƒÅ¡ -> Ãš
    "$([char]195)$([char]145)" = "$([char]209)"; # Ãƒâ€˜ -> Ã‘
    # --- SIGNOS Y OTROS ---
    "$([char]194)$([char]191)" = "$([char]191)"; # ¿ -> ¿
    "$([char]194)$([char]161)" = "$([char]161)"; # ¡ -> ¡
    "$([char]226)$([char]128)$([char]156)" = "$([char]8220)"; # Ã¢â‚¬Å“ -> â€œ
    "$([char]226)$([char]128)$([char]157)" = "$([char]8221)"; # Ã¢â‚¬  -> â€
    "$([char]226)$([char]128)$([char]153)" = "$([char]8217)"; # Ã¢â‚¬â„¢ -> â€™
    "$([char]226)$([char]128)$([char]166)" = "$([char]8230)"; # Ã¢â‚¬Â¦ -> â€¦
}
#endregion

#region Funciones de Lógica Interna
function _Analyze-Directory {
    param([hashtable]$Config)

    Write-Styled -Type Step -Message "Iniciando análisis en: $($Config.TargetDirectory)"
    Write-Styled -Type Info -Message "Extensiones objetivo: $($Config.TargetExtensions -join ', ')"

    $filesToProcess = @()
    $allFiles = Get-ChildItem -Path $Config.TargetDirectory -Recurse -Include $Config.TargetExtensions -File -ErrorAction SilentlyContinue

    if ($allFiles.Count -eq 0) {
        Write-Styled -Type Warn -Message "No se encontraron ficheros que coincidan con las extensiones en el directorio especificado."
        return $null
    }

    $utf8Bom = [byte[]](0xEF, 0xBB, 0xBF)

    foreach ($file in $allFiles) {
        $reason = ""
        try {
            $contentLines = Get-Content -Path $file.FullName -ErrorAction Stop
            $rawContent = $contentLines -join "`n" # Usar `n como separador neutro para el análisis

            # Comprobación 1: BOM (Siempre se comprueba, ya que la corrección es guardando como UTF8 con BOM)
            $fileBytes = Get-Content -Path $file.FullName -Encoding Byte -TotalCount 3 -ErrorAction Stop
            if ($fileBytes.Length -lt 3 -or $fileBytes[0] -ne $utf8Bom[0] -or $fileBytes[1] -ne $utf8Bom[1] -or $fileBytes[2] -ne $utf8Bom[2]) {
                $reason += "[Sin BOM/Codificación incorrecta] "
            }

            # Comprobación 2: Caracteres corruptos
            if ($Config.Rules.FixCharacterEncoding) {
                foreach ($key in $global:CorruptionMap.Keys) { if ($rawContent.Contains($key)) { $reason += "[Caracteres corruptos] "; break } }
            }

            # Comprobación 3: Finales de línea
            if ($Config.Rules.NormalizeLineEndings -and $rawContent -match "(?<!`r)`n|`r(?!`n)") {
                $reason += "[Finales de línea mixtos] "
            }

            # Comprobación 4: Espacios finales
            if ($Config.Rules.TrimTrailingWhitespace -and ($contentLines | Where-Object { $_ -match '\s+$' })) {
                $reason += "[Espacios finales] "
            }

            # Comprobación 5: Nueva línea final
            if ($Config.Rules.EnsureFinalNewline -and -not ($rawContent.EndsWith("`n"))) {
                $reason += "[Sin nueva línea final] "
            }

            if ($reason) {
                $filesToProcess += [PSCustomObject]@{ Path = $file.FullName; Reason = $reason.Trim() }
            }
        } catch {
            Write-Styled -Type Error -Message "No se pudo analizar el fichero '$($file.Name)'. Saltando. Error: $($_.Exception.Message)"
        }
    }

    return $filesToProcess
}

function _Execute-Sanitization {
    param(
        [array]$FilesToProcess,
        [hashtable]$Config
    )
    Write-Styled -Type Step -Message "Iniciando proceso de saneamiento para $($FilesToProcess.Count) fichero(s)..."
    $failedFiles = @()
    $newLineChar = if ($Config.LineEnding -eq 'LF') { "`n" } else { "`r`n" }

    foreach ($fileInfo in $FilesToProcess) {
        Write-Styled -Type SubStep -Message "Procesando: $($fileInfo.Path)"
        try {
            $fileContentLines = Get-Content -Path $fileInfo.Path -ErrorAction Stop
            $processedLines = @()

            foreach ($line in $fileContentLines) {
                $processedLine = $line
                if ($Config.Rules.TrimTrailingWhitespace) { $processedLine = $processedLine.TrimEnd() }
                $processedLines += $processedLine
            }

            $fullContent = $processedLines -join $newLineChar

            if ($Config.Rules.EnsureFinalNewline -and -not ($fullContent.EndsWith($newLineChar))) {
                $fullContent += $newLineChar
            }

            if ($Config.Rules.FixCharacterEncoding) {
                foreach ($entry in $global:CorruptionMap.GetEnumerator()) {
                    if ($fullContent.Contains($entry.Key)) {
                        $fullContent = $fullContent.Replace($entry.Key, $entry.Value)
                    }
                }
            }

            # La corrección de finales de línea y BOM se aplica al guardar
            Set-Content -Path $fileInfo.Path -Value $fullContent -Encoding UTF8 -Force -NoNewline -ErrorAction Stop
            Write-Styled -Type Success -Message "Fichero saneado y guardado como UTF-8 con BOM."

        } catch {
            Write-Styled -Type Error -Message "No se pudo procesar este fichero. Error: $($_.Exception.Message)"
            $failedFiles += [PSCustomObject]@{ Path = $fileInfo.Path; Error = $_.Exception.Message }
        }
    }

    Write-Styled -Type Step -Message "Proceso de saneamiento finalizado."
    if ($failedFiles.Count -gt 0) {
        Write-Styled -Type Warn -Message "$($failedFiles.Count) fichero(s) no pudieron ser procesados. Revise los errores anteriores."
    }
}
#endregion

#region Funciones de Menú y UI
function _Show-Current-Configuration {
    Show-Header -Title "Configuración Actual de Saneamiento"
    Write-Styled -Type Title -Message "Directorio Objetivo:"
    Write-Styled -Type Info -Message "  $($global:CodeQualityConfig.TargetDirectory)"
    Write-Host

    Write-Styled -Type Title -Message "Extensiones Objetivo:"
    Write-Styled -Type Info -Message "  $($global:CodeQualityConfig.TargetExtensions -join ', ')"
    Write-Host

    Write-Styled -Type Title -Message "Reglas de Saneamiento:"
    $global:CodeQualityConfig.Rules.GetEnumerator() | ForEach-Object {
        $status = if ($_.Value) { "[ACTIVADO]" } else { "[DESACTIVADO]" }
        $color = if ($_.Value) { 'Success' } else { 'Error' }
        Write-Styled -Type $color -Message "  $($_.Name): $status"
    }
    Write-Host

    Write-Styled -Type Title -Message "Formato de Fin de Línea:"
    Write-Styled -Type Info -Message "  $($global:CodeQualityConfig.LineEnding)"
    Write-Host
}

function _Configure-Sanitization-Rules {
    $exitMenu = $false
    while (-not $exitMenu) {
        Show-Header -Title "Configurar Reglas de Saneamiento"

        # Opciones de Reglas
        Write-Styled -Type Step -Message "[1] Cambiar Directorio Objetivo"
        Write-Styled -Type Info -Message "    Actual: $($global:CodeQualityConfig.TargetDirectory)"
        Write-Styled -Type Step -Message "[2] Cambiar Extensiones Objetivo"
        Write-Styled -Type Info -Message "    Actual: $($global:CodeQualityConfig.TargetExtensions -join ', ')"
        Write-Styled -Type Step -Message "[3] Cambiar Formato de Fin de Línea (Actual: $($global:CodeQualityConfig.LineEnding))"

        # Opciones de Activación/Desactivación
        $rules = $global:CodeQualityConfig.Rules.GetEnumerator() | Sort-Object Name
        for ($i = 0; $i -lt $rules.Count; $i++) {
            $rule = $rules[$i]
            $status = if ($rule.Value) { "[ACTIVADO]" } else { "[DESACTIVADO]" }
            Write-Styled -Type Step -Message "[$($i + 4)] Activar/Desactivar $($rule.Name) $status"
        }

        Write-Styled -Type Step -Message "[0] Guardar y Volver"

        $validChoices = 0..($rules.Count + 3)
        $choice = Invoke-MenuPrompt -ValidChoices $validChoices -PromptMessage "Seleccione una opción para modificar"

        switch ($choice) {
            '0' { $exitMenu = $true; continue }
            '1' {
                $newDir = Read-Host "  -> Introduzca la nueva ruta del directorio objetivo"
                if (Test-Path $newDir -PathType Container) {
                    $global:CodeQualityConfig.TargetDirectory = $newDir
                    Write-Styled -Type Success -Message "Directorio actualizado."
                } else {
                    Write-Styled -Type Error -Message "La ruta proporcionada no es un directorio válido."
                }
                Start-Sleep -Seconds 1
            }
            '2' {
                $newExts = Read-Host "  -> Introduzca las nuevas extensiones separadas por comas (ej: *.txt,*.log)"
                $global:CodeQualityConfig.TargetExtensions = $newExts -split ',' | ForEach-Object { $_.Trim() }
                Write-Styled -Type Success -Message "Extensiones actualizadas."
                Start-Sleep -Seconds 1
            }
            '3' {
                $global:CodeQualityConfig.LineEnding = if ($global:CodeQualityConfig.LineEnding -eq 'CRLF') { 'LF' } else { 'CRLF' }
                Write-Styled -Type Success -Message "Formato de fin de línea cambiado a $($global:CodeQualityConfig.LineEnding)."
                Start-Sleep -Seconds 1
            }
            default {
                $ruleIndex = [int]$choice - 4
                $ruleName = $rules[$ruleIndex].Name
                $global:CodeQualityConfig.Rules[$ruleName] = -not $global:CodeQualityConfig.Rules[$ruleName]
            }
        }
    }
}

function _Run-Sanitization-Process {
    $filesToFix = _Analyze-Directory -Config $global:CodeQualityConfig

    if ($null -eq $filesToFix) { # Caso de no encontrar ficheros
        Pause-And-Return
        return
    }

    if ($filesToFix.Count -eq 0) {
        Write-Styled -Type Success -Message "¡Análisis completo! Todos los ficheros cumplen con los estándares configurados."
        Pause-And-Return
        return
    }

    Show-Header -Title "Análisis Completado"
    Write-Styled -Type Warn -Message "Se encontraron $($filesToFix.Count) fichero(s) que necesitan ser saneados:"
    $filesToFix | ForEach-Object { Write-Styled -Type Info -Message "  - $($_.Path) ($($_.Reason))" }
    Write-Host

    $consent = Invoke-MenuPrompt -ValidChoices @('S', 'N') -PromptMessage "El script aplicará las correcciones configuradas. ¿Desea proceder? (S/N)"
    if ($consent -ne 'S') {
        Write-Styled -Type Error -Message "Operación cancelada por el usuario."
        Pause-And-Return
        return
    }

    _Execute-Sanitization -FilesToProcess $filesToFix -Config $global:CodeQualityConfig
    Pause-And-Return
}
#endregion

#region Punto de Entrada Principal de la Fase
function Invoke-Phase6_CodeQuality {
    $exitMenu = $false
    while (-not $exitMenu) {
        Show-Header -Title "FASE 6: Saneamiento y Calidad del Código"
        $menuOptions = @(
            @{ Description = "Analizar y Sanear Directorio"; Action = { _Run-Sanitization-Process } },
            @{ Description = "Configurar Reglas de Saneamiento"; Action = { _Configure-Sanitization-Rules } },
            @{ Description = "Ver Configuración Actual"; Action = { _Show-Current-Configuration; Pause-And-Return } }
        )

        for ($i = 0; $i -lt $menuOptions.Count; $i++) {
            Write-Styled -Type Step -Message "[$($i+1)] $($menuOptions[$i].Description)"
        }
        Write-Styled -Type Step -Message "[0] Volver al Menú Principal"
        Write-Host

        $choice = Invoke-MenuPrompt -ValidChoices @('1', '2', '3', '0')

        switch ($choice) {
            '0' { $exitMenu = $true }
            '1' { & $menuOptions[0].Action }
            '2' { & $menuOptions[1].Action }
            '3' { & $menuOptions[2].Action }
        }
    }
}
#endregion

Export-ModuleMember -Function *
