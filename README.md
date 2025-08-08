## Fénix - Motor de Aprovisionamiento para Windows

Script automatizado en PowerShell para la limpieza, optimización y aprovisionamiento estandarizado de sistemas Windows. Fénix automatiza tareas repetitivas y complejas a través de una interfaz de menú interactiva y catálogos `JSON` personalizables.

### Tabla de Contenidos

- [Características Principales](#características-principales)
- [Requisitos](#requisitos)
- [Instalación](#instalación)
- [Modo de Uso](#modo-de-uso)
- [Estructura del Proyecto](#estructura-del-proyecto)
- [Personalización de Catálogos](#personalización-de-catálogos)
- [Arquitectura y Lógica Interna](#arquitectura-y-lógica-interna)
- [Preguntas Frecuentes (FAQ)](#preguntas-frecuentes-faq)
- [Licencia](#licencia)

### Características Principales

#### Fase 1: Erradicación Completa de OneDrive
- Desinstalación de la aplicación OneDrive.
- Limpieza de componentes residuales (tareas programadas, claves del registro, etc.).
- Auditoría y reparación opcional de las rutas de carpetas de usuario (`User Shell Folders`).

#### Fase 2: Instalación Automatizada de Software
- Instalación desde catálogos `JSON` con un esquema de validación.
- Soporte dual para los gestores de paquetes **Chocolatey** y **Winget**.
- Opciones para instalar paquetes, actualizar los existentes y listar el estado del software del catálogo.

#### Fase 3: Optimización del Sistema (Tweaks)
- Aplicación de una variedad de ajustes del sistema desde un catálogo.
- Incluye ajustes para la barra de tareas, menú contextual, eliminación de bloatware (paquetes AppX) y configuración de planes de energía.
- Lógica de verificación para mostrar qué ajustes ya han sido aplicados.

#### Fase 4: Instalación y Configuración de WSL2
- Lógica robusta para instalar el Subsistema de Windows para Linux (WSL).
- Detección inteligente para verificar si WSL ya está instalado y operativo, guiando al usuario si se requiere un reinicio.
- Instalación automática de la distribución de Ubuntu por defecto.

#### Fase 5: Limpieza y Optimización del Sistema
- Menú de tareas de limpieza para optimizar el rendimiento del sistema.
- **Limpieza de Disco:** Elimina archivos temporales y residuales de Windows Update.
- **Optimización de Unidades:** Identifica si la unidad es SSD o HDD y aplica la optimización adecuada (ReTrim o Defrag).
- **Vaciar Papelera de Reciclaje:** Informa del número de archivos y el espacio que se liberará antes de confirmar.
- **Análisis de Procesos:** Muestra los procesos que más consumen CPU y memoria, manejando errores de "Acceso Denegado".

#### Fase 6: Saneamiento y Calidad del Código (Platzhalter)
- Fase reservada para futuras herramientas de formateo, linting y análisis estático del código.

#### Fase 7: Auditoría del Sistema y del Código
- **Informe de Estado:** Genera un informe completo en formato `Markdown` con todo el software instalado a través de Winget y Chocolatey, y todos los tweaks del sistema aplicados.
- **Auditoría de Seguridad del Código:** Escanea el propio código fuente de Fénix en busca de comandos potencialmente sensibles (`Invoke-Expression`, `Restart-Computer`, etc.) para ofrecer una total transparencia sobre sus operaciones.

#### Arquitectura General
- **Orquestador Central (`Phoenix-Launcher.ps1`):** Punto de entrada único que gestiona el menú, el estado y los módulos.
- **Diseño Modular:** Cada fase principal reside en su propio módulo `.ps1`.
- **Manejo de Errores Fiable:** Utiliza un wrapper (`Invoke-NativeCommand`) para ejecutar comandos externos, previniendo falsos positivos.
- **Registro Automático:** Toda la salida de la consola se guarda en un archivo de log (`.txt`).
- **Experiencia de Usuario:** Lógica de menú que no parpadea y barras de progreso con temporizadores fiables.

### Requisitos

- **Sistema Operativo:** Windows 10 (1809+) o Windows 11.
- **PowerShell:** Versión 5.1 o superior.
- **Privilegios:** Se requieren derechos de Administrador (el script intentará auto-elevarse).

### Instalación

1.  Clona o descarga este repositorio en tu máquina.
    ```bash
    git clone https://github.com/miguel-cinsfran/Fenix
    cd fenix
    ```

2.  Asegúrate de que la estructura de directorios se mantiene intacta.
3.  Si PowerShell restringe la ejecución de scripts, abre una terminal de PowerShell como Administrador y ejecuta:
    ```powershell
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process -Force
    ```

### Modo de Uso

1.  Haz clic derecho sobre `Phoenix-Launcher.ps1` y selecciona **"Ejecutar con PowerShell"**.
2.  Aparecerá una advertencia. Debes escribir `ACEPTO` para continuar.
3.  Usa el menú principal para seleccionar la fase que deseas ejecutar.

### Estructura del Proyecto

```text
/
├── 📂 assets/
│   ├── 📂 catalogs/
│   │   ├── chocolatey_catalog.json
│   │   ├── system_cleanup.json
│   │   ├── system_tweaks.json
│   │   └── winget_catalog.json
│   └── 📂 themes/
│       └── default.json
├── 📂 modules/
│   ├── 📂 package_managers/
│   │   ├── chocolatey.psm1
│   │   └── winget.psm1
│   ├── Phase1-OneDrive.psm1
│   ├── Phase2-Software.psm1
│   ├── Phase3-Tweaks.psm1
│   ├── Phase4-WSL.psm1
│   ├── Phase5-Cleanup.psm1
│   ├── Phase6-CodeQuality.psm1
│   ├── Phase7-Audit.psm1
│   └── Phoenix-Utils.psm1
├── 📂 tests/
│   └── Utils.Tests.ps1
├── 📜 Phoenix-Launcher.ps1
├── 📜 README.md
└── 📜 settings.psd1
```

### Pruebas y Calidad del Código

El proyecto ha incorporado **Pester** para la realización de pruebas unitarias, asegurando la fiabilidad y facilitando el mantenimiento a largo plazo.

#### Ejecutar las Pruebas

Para ejecutar la suite de pruebas, asegúrate de tener el módulo de Pester instalado y luego ejecuta el siguiente comando desde la raíz del proyecto en una terminal de PowerShell:

```powershell
# Instalar Pester si no está presente
if (-not (Get-Module -ListAvailable -Name Pester)) {
    Install-Module -Name Pester -Force -SkipPublisherCheck -Scope CurrentUser
}

# Ejecutar las pruebas
Invoke-Pester -Path ./tests/ -Output Detailed
```

### Personalización de Catálogos

Para personalizar las operaciones, simplemente edita los archivos `.json` correspondientes en la carpeta `assets/catalogs`. Esto te permite definir qué software instalar, qué ajustes aplicar y qué tareas de limpieza ejecutar.

### Arquitectura y Lógica Interna

-   **Orquestador Central (`Phoenix-Launcher.ps1`):** No contiene lógica de aprovisionamiento. Su función es cargar módulos, gestionar un objeto de estado global (`$state`) y mostrar el menú.
-   **Módulos de Fase (`Phase*.ps1`):** Son autocontenidos. Cada módulo exporta una función principal que recibe el objeto `$state`, lo modifica y lo retorna.
-   **Objeto de Estado (`$state`):** Un objeto `[PSCustomObject]` que se pasa a través de todas las funciones para centralizar el estado de la ejecución. Su carga es retrocompatible con versiones antiguas del script.
-   **Manejo de Errores:** El script se basa en la función `Invoke-NativeCommand` para ejecutar comandos externos de forma fiable. Este wrapper captura flujos de salida y error, y comprueba los códigos de salida y el contenido del texto para detectar fallos.
-   **Utilidades Compartidas (`Phoenix-Utils.ps1`):** Proporciona funciones comunes para la UI, asegurando una apariencia consistente y un manejo de trabajos en segundo plano fiable.

### Preguntas Frecuentes (FAQ)

<details>
<summary><strong>¿Es seguro ejecutar este script?</strong></summary>

El script está diseñado para ser seguro, pero realiza cambios importantes. Incluye varias salvaguardas:
- Requiere consentimiento explícito escribiendo "ACEPTO".
- Aísla la lógica en módulos para reducir el riesgo de efectos secundarios.
- Genera un log completo de cada operación.
- Utiliza un manejo de errores robusto para detenerse si algo sale mal.
</details>

<details>
<summary><strong>¿Qué hace exactamente la "erradicación" de OneDrive?</strong></summary>

Es más que una simple desinstalación. El proceso incluye: detener el proceso, ejecutar los desinstaladores oficiales, eliminar tareas programadas, limpiar claves del registro y, finalmente, auditar (y opcionalmente reparar) las rutas de las carpetas personales del usuario.
</details>

### Licencia

Este proyecto se distribuye bajo la Licencia BLABLA. Consulta el archivo `LICENSE` para más detalles.
