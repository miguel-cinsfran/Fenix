<#
.SYNOPSIS
    Una herramienta de saneamiento de ficheros para desarrolladores.
.DESCRIPTION
    Este script busca de forma recursiva y corrige problemas comunes en ficheros de texto,
    haciéndolo ideal para mantener la consistencia en proyectos de software.

    Capacidades:
    1. Repara caracteres corruptos del español (ej. 'ó' -> 'ó').
    2. Estandariza los finales de línea a CRLF (Windows) o LF (Unix).
    3. Elimina espacios y tabulaciones innecesarias al final de cada línea.
    4. Asegura que cada fichero termine con un carácter de nueva línea.
    5. Convierte los ficheros a la codificación UTF-8 con BOM para máxima compatibilidad.

    El script es seguro: primero analiza y presenta un informe detallado, y no realiza
    ningún cambio sin la confirmación explícita del usuario.
.NOTES
    Versión: 2.4
    Autor: miguel-cinsfran
    Revisión: Reescrito el diccionario de reparación para construir tanto las CLAVES
             como los VALORES a partir de sus códigos de carácter, garantizando
             la inmunidad total a errores de sintaxis y codificación.
#>

#region CONFIGURACIÓN
# --- Extensiones de fichero a procesar ---
$targetExtensions = @("*.ps1", "*.json", "*.md", "*.txt", "*.csv", "*.xml", "*.html", "*.css", "*.js")

# --- Opciones de Saneamiento (Activa o desactiva las correcciones) ---
$fixCharacterEncoding = $true       # ¿Reparar caracteres como 'ó' a 'ó'?
$normalizeLineEndings = $true       # ¿Estandarizar finales de línea?
$trimTrailingWhitespace = $true       # ¿Eliminar espacios/tabs al final de las líneas?
$ensureFinalNewline = $true       # ¿Asegurar que el fichero termine con una nueva línea?

# --- Configuración de Final de Línea (Elige el estándar a aplicar) ---
# Usa 'CRLF' para Windows (predeterminado) o 'LF' para Unix/Linux/macOS.
$targetLineEnding = 'CRLF' # Opciones: 'CRLF', 'LF'

# --- Diccionario de reparación de caracteres corruptos (VERSIÓN DEFINITIVA) ---
# Tanto las CLAVES como los VALORES se construyen a partir de sus códigos de carácter.
# Esto hace que el script sea 100% inmune a errores de codificación/copiar-pegar.
$corruptionMap = @{
    # --- MINÚSCULAS ---
    "$([char]195)$([char]161)" = "$([char]225)"; # á -> á
    "$([char]195)$([char]169)" = "$([char]233)"; # é -> é
    "$([char]195)$([char]173)" = "$([char]237)"; # í -> í
    "$([char]195)$([char]179)" = "$([char]243)"; # ó -> ó
    "$([char]195)$([char]186)" = "$([char]250)"; # ú -> ú
    "$([char]195)$([char]177)" = "$([char]241)"; # ñ -> ñ
    # --- MAYÚSCULAS ---
    "$([char]195)$([char]129)" = "$([char]193)"; # Ã  -> Á
    "$([char]195)$([char]137)" = "$([char]201)"; # Ã‰ -> É
    "$([char]195)$([char]141)" = "$([char]205)"; # Ã  -> Í
    "$([char]195)$([char]147)" = "$([char]211)"; # Ã“ -> Ó
    "$([char]195)$([char]154)" = "$([char]218)"; # Ãš -> Ú
    "$([char]195)$([char]145)" = "$([char]209)"; # Ã‘ -> Ñ
    # --- SIGNOS Y OTROS ---
    "$([char]194)$([char]191)" = "$([char]191)"; # ¿ -> ¿
    "$([char]194)$([char]161)" = "$([char]161)"; # ¡ -> ¡
    "$([char]226)$([char]128)$([char]156)" = "$([char]8220)"; # â€œ -> “ (Left Double Quote)
    "$([char]226)$([char]128)$([char]157)" = "$([char]8221)"; # â€  -> ” (Right Double Quote)
    "$([char]226)$([char]128)$([char]153)" = "$([char]8217)"; # â€™ -> ’ (Right Single Quote)
    "$([char]226)$([char]128)$([char]166)" = "$([char]8230)"; # â€¦ -> … (Ellipsis)
}

# --- Definiciones Internas ---
$utf8Bom = [byte[]](0xEF, 0xBB, 0xBF)
$newLineChar = if ($targetLineEnding -eq 'LF') { "`n" } else { "`r`n" }
#endregion

#region LÓGICA PRINCIPAL
$startTimestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$transcriptLogFile = Join-Path $PSScriptRoot "Sanitize-Files-Transcript-$startTimestamp.log"
$errorLogFile = Join-Path $PSScriptRoot "Sanitize-Files-FailedFiles-$startTimestamp.log"

try { Start-Transcript -Path $transcriptLogFile -Append:$false } catch {}

try {
    Clear-Host
    Write-Host "--- Herramienta de Saneamiento de Ficheros v2.4 ---" -ForegroundColor Cyan
    Write-Host "Analizando ficheros en: $PSScriptRoot`n"

    # 1. FASE DE ANÁLISIS
    $filesToProcess = @()
    $allFiles = Get-ChildItem -Path $PSScriptRoot -Recurse -Include $targetExtensions -File -ErrorAction SilentlyContinue

    foreach ($file in $allFiles) {
        $reason = ""
        $contentLines = Get-Content -Path $file.FullName -ErrorAction SilentlyContinue
        $rawContent = $contentLines -join "`n" # Usar `n como separador neutro para el análisis

        # Comprobación 1: BOM
        $fileBytes = Get-Content -Path $file.FullName -Encoding Byte -TotalCount 3 -ErrorAction SilentlyContinue
        if ($fileBytes.Length -lt 3 -or $fileBytes[0] -ne $utf8Bom[0] -or $fileBytes[1] -ne $utf8Bom[1] -or $fileBytes[2] -ne $utf8Bom[2]) {
            $reason += "[Sin BOM] "
        }

        # Comprobación 2: Caracteres corruptos
        if ($fixCharacterEncoding) {
            foreach ($key in $corruptionMap.Keys) { if ($rawContent.Contains($key)) { $reason += "[Corrupto] "; break } }
        }

        # Comprobación 3: Finales de línea
        if ($normalizeLineEndings -and $rawContent -match "(?<!`r)`n|`r(?!`n)") {
            $reason += "[Finales de Línea Mixtos] "
        }

        # Comprobación 4: Espacios finales
        if ($trimTrailingWhitespace -and ($contentLines | Where-Object { $_ -match '\s+$' })) {
            $reason += "[Espacios Finales] "
        }

        # Comprobación 5: Nueva línea final
        if ($ensureFinalNewline -and -not ($rawContent.EndsWith("`n"))) {
            $reason += "[Sin Nueva Línea Final] "
        }

        if ($reason) {
            $filesToProcess += [PSCustomObject]@{ Path = $file.FullName; Reason = $reason.Trim() }
        }
    }

    # 2. FASE DE CONFIRMACIÓN
    if ($filesToProcess.Count -eq 0) {
        Write-Host "`nAnálisis completo. ¡Todos los ficheros cumplen con los estándares configurados!" -ForegroundColor Green
        Read-Host "`nPresione Enter para salir."; exit
    }

    Write-Host "`nAnálisis completo. Se encontraron $($filesToProcess.Count) ficheros que necesitan ser saneados:" -ForegroundColor Yellow
    $filesToProcess | ForEach-Object { Write-Host "  - $($_.Path) ($($_.Reason))" }

    Write-Host "`nEl script aplicará las correcciones configuradas y guardará los ficheros como UTF-8 con BOM." -ForegroundColor White
    if ((Read-Host "¿Desea proceder con los cambios? (S/N)").Trim().ToUpper() -ne 'S') {
        Write-Host "`nOperación cancelada. No se ha modificado ningún fichero." -ForegroundColor Red
        Read-Host "Presione Enter para salir."; exit
    }

    # 3. FASE DE EJECUCIÓN
    Write-Host "`nIniciando proceso de saneamiento..." -ForegroundColor Cyan
    $failedFiles = @()

    foreach ($fileInfo in $filesToProcess) {
        Write-Host "Procesando: $($fileInfo.Path)" -ForegroundColor White
        try {
            $fileContentLines = Get-Content -Path $fileInfo.Path -ErrorAction Stop
            $processedLines = @()
            $report = ""

            foreach ($line in $fileContentLines) {
                $processedLine = $line
                if ($trimTrailingWhitespace) { $processedLine = $processedLine.TrimEnd() }
                $processedLines += $processedLine
            }
            if ($trimTrailingWhitespace) { $report += "[Espacios Finales Limpiados] " }

            $fullContent = $processedLines -join $newLineChar
            if ($normalizeLineEndings) { $report += "[Finales de Línea Normalizados] " }

            if ($ensureFinalNewline -and -not ($fullContent.EndsWith($newLineChar))) {
                $fullContent += $newLineChar
                $report += "[Nueva Línea Final Añadida] "
            }

            if ($fixCharacterEncoding) {
                foreach ($entry in $corruptionMap.GetEnumerator()) {
                    if ($fullContent.Contains($entry.Key)) {
                        $fullContent = $fullContent.Replace($entry.Key, $entry.Value)
                    }
                }
                $report += "[Caracteres Reparados] "
            }

            Set-Content -Path $fileInfo.Path -Value $fullContent -Encoding UTF8 -Force -NoNewline -ErrorAction Stop
            $report += "[Guardado como UTF-8 con BOM]"
            Write-Host "  - [ÉXITO] $report" -ForegroundColor Green

        } catch {
            $errorMessage = "No se pudo procesar este fichero. Error: $($_.Exception.Message)"
            Write-Host "  - [ERROR] $errorMessage" -ForegroundColor Red
            $failedFiles += [PSCustomObject]@{ Path = $fileInfo.Path; Error = $_.Exception.Message }
        }
    }

    # 4. FASE DE REPORTE FINAL
    Write-Host "`n--- Proceso Finalizado ---" -ForegroundColor Cyan
    if ($failedFiles.Count -gt 0) {
        Write-Host "`n¡ATENCIÓN! Se encontraron $($failedFiles.Count) errores durante el proceso:" -ForegroundColor Red
        $failedFiles | ForEach-Object { Write-Host "  - Fichero: $($_.Path)`n    Error: $($_.Error)" -ForegroundColor Yellow }
        $errorContent = $failedFiles | ForEach-Object { "Fichero: $($_.Path)`r`nError: $($_.Error)`r`n---" }
        Set-Content -Path $errorLogFile -Value $errorContent -Encoding UTF8
        Write-Host "`nSe ha creado un fichero de log con los detalles de los errores en: $errorLogFile" -ForegroundColor Yellow
    }
    Write-Host "`nSe ha guardado un log completo de esta sesión en: $transcriptLogFile" -ForegroundColor Gray

} finally {
    Read-Host "`nPresione Enter para salir."
    Stop-Transcript
}
#endregion
