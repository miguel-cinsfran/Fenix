# Fénix - Motor de Aprovisionamiento para Windows

**Observación**: el Readme no está actualizado aún a los últimos cambios realizados. La implementación de una Phase3, por ejemplo.

Script automatizado en PowerShell para la limpieza y el aprovisionamiento estandarizado de sistemas Windows. Fénix automatiza tareas repetitivas como la erradicación completa de OneDrive y la instalación masiva de software a través de catálogos `JSON` personalizables.

## Tabla de Contenidos

- [Características Principales](#características-principales)
- [Requisitos](#requisitos)
- [Instalación](#instalación)
- [Modo de Uso](#modo-de-uso)
- [Estructura del Proyecto](#estructura-del-proyecto)
- [Configuración de Software](#configuración-de-software)
- [Arquitectura y Lógica Interna](#arquitectura-y-lógica-interna)
- [Preguntas Frecuentes (FAQ)](#preguntas-frecuentes-faq)
- [Licencia](#licencia)

## Características Principales

#### Fase 1: Erradicación Completa de OneDrive
- Desinstalación de la aplicación OneDrive.
- Limpieza de componentes residuales (tareas programadas, claves del registro, etc.).
- Auditoría y reparación opcional de las rutas de carpetas de usuario (`User Shell Folders`) para que no apunten a directorios de OneDrive.

#### Fase 2: Instalación Automatizada de Software
- Instalación desde catálogos `JSON` con un esquema de validación.
- Soporte dual para los gestores de paquetes **Chocolatey** y **Winget**.
- Verificación previa para omitir paquetes que ya están instalados.
- Manejo específico para paquetes con IDs inconsistentes (común en la `msstore`) mediante un campo de verificación (`checkName`).

#### Arquitectura General
- **Orquestador Central (`Phoenix-Launcher.ps1`):** Punto de entrada único que gestiona el menú, el estado y los módulos.
- **Diseño Modular:** Cada fase principal (OneDrive, Software) reside en su propio módulo `.ps1`.
- **Registro Automático:** Toda la salida de la consola se guarda en un archivo de log (`.txt`) para su posterior revisión.

## Requisitos

- **Sistema Operativo:** Windows 10 (1809+) o Windows 11.
- **PowerShell:** Versión 5.1 o superior.
- **Privilegios:** Se requieren derechos de Administrador (el script intentará auto-elevarse si no se ejecuta como tal).

## Instalación

1.  Clona o descarga este repositorio en tu máquina.
    ```bash
    git clone https://github.com/miguel-cinsfran/Fenix
    cd fenix
    ```

2.  Asegúrate de que la estructura de directorios (`modules`, `assets`) se mantiene intacta.
3.  Si PowerShell restringe la ejecución de scripts, abre una terminal de PowerShell y ejecuta:
    ```powershell
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
    ```

## Modo de Uso

1.  Haz clic derecho sobre `Phoenix-Launcher.ps1` y selecciona **"Ejecutar con PowerShell"**. El script solicitará elevación de privilegios si es necesario.
2.  Aparecerá una advertencia. Debes escribir `ACEPTO` para continuar.
    ```text
    ADVERTENCIA Y CONSENTIMIENTO
    Este script realizará cambios significativos en el sistema...

    Escriba 'ACEPTO' para confirmar que entiende los riesgos y desea continuar: ACEPTO
    ```

3.  Usa el menú principal para seleccionar la fase que deseas ejecutar.
    ```text
    Motor de Aprovisionamiento Fénix
    ---

    Ejecutar FASE 1: Erradicación de OneDrive [PENDIENTE]
    Ejecutar FASE 2: Instalación de Software [PENDIENTE]
    [R] Refrescar Menú
    [Q] Salir

    Seleccione una opción:
    ```
- **Log:** Al finalizar, encontrarás un archivo `Provision-Log-Phoenix-*.txt` en el directorio raíz con un registro completo de todas las operaciones.

## Estructura del Proyecto

```text
/
├── 📄 Phoenix-Launcher.ps1      # Orquestador principal
├── 📄 README.md                 # Esta documentación
├── 📂 modules/
│   ├── Phoenix-Utils.ps1       # Funciones de UI y utilidades compartidas
│   ├── Phase1-OneDrive.ps1     # Lógica para la erradicación de OneDrive
│   └── Phase2-Software.ps1     # Lógica para la instalación de software
└── 📂 assets/
    ├── catalog_schema.json     # Esquema JSON que define la estructura de los catálogos
    └── 📂 catalogs/
        ├── chocolatey_catalog.json # Lista de paquetes a instalar con Chocolatey
        └── winget_catalog.json     # Lista de paquetes a instalar con Winget
```

## Configuración de Software

Para personalizar el software a instalar, simplemente edita los archivos `chocolatey_catalog.json` y `winget_catalog.json` ubicados en la carpeta `assets/catalogs`.

La estructura de cada entrada se define en `catalog_schema.json`:

| Propiedad | Descripción | Ejemplo |
| :--- | :--- | :--- |
| `installId` | **(Requerido)** El ID exacto del paquete para `choco install` o `winget install`. | `"git"` o `"Microsoft.VisualStudioCode"` |
| `name` | (Opcional) Un nombre descriptivo para mostrar en la consola. Si se omite, se usa el `installId`. | `"Visual Studio Code"` |
| `checkName` | (Opcional) Usado por Winget para paquetes cuyo ID de instalación no coincide con el nombre en `winget list`. Esencial para paquetes de la MSStore. | `"WhatsApp"` |
| `source` | (Opcional) La fuente específica para Winget (`msstore` o `winget`). | `"msstore"` |
| `special_params` | (Opcional) Parámetros de instalación adicionales, solo para Chocolatey. | `"/Password:1122"` |

**Ejemplo (`winget_catalog.json`):**
```json
{
    "installId": "9NKSQGP7F2NH", 
    "checkName": "WhatsApp", 
    "name": "WhatsApp", 
    "source": "msstore" 
}
```

## Arquitectura y Lógica Interna

El script opera sobre unos principios clave para garantizar robustez y modularidad:

-   **Orquestador Central (`Phoenix-Launcher.ps1`):** No contiene lógica de aprovisionamiento. Su única función es cargar módulos, gestionar un objeto de estado global (`$state`) y mostrar el menú principal.
-   **Módulos de Fase (`Phase*.ps1`):** Son autocontenidos. Cada módulo exporta una función principal (ej. `Invoke-Phase1_OneDrive`) que recibe el objeto `$state`, lo modifica y lo retorna al orquestador.
-   **Objeto de Estado (`$state`):** Un objeto `[PSCustomObject]` que se pasa a través de todas las funciones. Centraliza el estado de la ejecución (ej. `$state.OneDriveErradicated`, `$state.FatalErrorOccurred`) y recopila acciones manuales requeridas (`$state.ManualActions`).
-   **Manejo de Errores:** Si una fase encuentra un error crítico, establece `$state.FatalErrorOccurred = $true`. El orquestador y los demás módulos comprueban este estado para detener la ejecución y evitar daños mayores.
-   **Utilidades Compartidas (`Phoenix-Utils.ps1`):** Proporciona funciones comunes para la interfaz de usuario (`Show-Header`, `Write-Styled`), asegurando una apariencia consistente en toda la aplicación.

## Preguntas Frecuentes (FAQ)

<details>
<summary><strong>¿Es seguro ejecutar este script?</strong></summary>

El script está diseñado para ser seguro, pero realiza cambios importantes en el sistema. Incluye varias salvaguardas:
- Requiere consentimiento explícito escribiendo "ACEPTO".
- Aísla la lógica en módulos para reducir el riesgo de efectos secundarios inesperados.
- Genera un log completo de cada operación para una auditoría sencilla.
</details>

<details>
<summary><strong>¿Qué hace exactamente la "erradicación" de OneDrive?</strong></summary>

Es más que una simple desinstalación. El proceso incluye: detener el proceso, ejecutar los desinstaladores oficiales de forma silenciosa, eliminar tareas programadas, limpiar claves del registro que habilitan la integración con el Explorador de Archivos y, finalmente, auditar (y opcionalmente reparar) las rutas de las carpetas personales del usuario.
</details>

## Licencia

Este proyecto se distribuye bajo la Licencia BLABLA. Consulta el archivo `LICENSE` para más detalles.