## FÃ©nix - Motor de Aprovisionamiento para Windows

Script automatizado en PowerShell para la limpieza, optimizaciÃ³n y aprovisionamiento estandarizado de sistemas Windows. FÃ©nix automatiza tareas repetitivas y complejas a travÃ©s de una interfaz de menÃº interactiva y catÃ¡logos `JSON` personalizables.

### Tabla de Contenidos

- [CaracterÃ­sticas Principales](#caracterÃ­sticas-principales)
- [Requisitos](#requisitos)
- [InstalaciÃ³n](#instalaciÃ³n)
- [Modo de Uso](#modo-de-uso)
- [Estructura del Proyecto](#estructura-del-proyecto)
- [PersonalizaciÃ³n de CatÃ¡logos](#personalizaciÃ³n-de-catÃ¡logos)
- [Arquitectura y LÃ³gica Interna](#arquitectura-y-lÃ³gica-interna)
- [Preguntas Frecuentes (FAQ)](#preguntas-frecuentes-faq)
- [Licencia](#licencia)

### CaracterÃ­sticas Principales

#### Fase 1: ErradicaciÃ³n Completa de OneDrive
- DesinstalaciÃ³n de la aplicaciÃ³n OneDrive.
- Limpieza de componentes residuales (tareas programadas, claves del registro, etc.).
- AuditorÃ­a y reparaciÃ³n opcional de las rutas de carpetas de usuario (`User Shell Folders`).

#### Fase 2: InstalaciÃ³n Automatizada de Software
- InstalaciÃ³n desde catÃ¡logos `JSON` con un esquema de validaciÃ³n.
- Soporte dual para los gestores de paquetes **Chocolatey** y **Winget**.
- Opciones para instalar paquetes, actualizar los existentes y listar el estado del software del catÃ¡logo.

#### Fase 3: OptimizaciÃ³n del Sistema (Tweaks)
- AplicaciÃ³n de una variedad de ajustes del sistema desde un catÃ¡logo.
- Incluye ajustes para la barra de tareas, menÃº contextual, eliminaciÃ³n de bloatware (paquetes AppX) y configuraciÃ³n de planes de energÃ­a.
- LÃ³gica de verificaciÃ³n para mostrar quÃ© ajustes ya han sido aplicados.

#### Fase 4: InstalaciÃ³n y ConfiguraciÃ³n de WSL2
- LÃ³gica robusta para instalar el Subsistema de Windows para Linux (WSL).
- DetecciÃ³n inteligente para verificar si WSL ya estÃ¡ instalado y operativo, guiando al usuario si se requiere un reinicio.
- InstalaciÃ³n automÃ¡tica de la distribuciÃ³n de Ubuntu por defecto.

#### Fase 5: Limpieza y OptimizaciÃ³n del Sistema
- MenÃº de tareas de limpieza para optimizar el rendimiento del sistema.
- **Limpieza de Disco:** Elimina archivos temporales y residuales de Windows Update.
- **OptimizaciÃ³n de Unidades:** Identifica si la unidad es SSD o HDD y aplica la optimizaciÃ³n adecuada (ReTrim o Defrag).
- **Vaciar Papelera de Reciclaje:** Informa del nÃºmero de archivos y el espacio que se liberarÃ¡ antes de confirmar.
- **AnÃ¡lisis de Procesos:** Muestra los procesos que mÃ¡s consumen CPU y memoria, manejando errores de "Acceso Denegado".

#### Arquitectura General
- **Orquestador Central (`Phoenix-Launcher.ps1`):** Punto de entrada Ãºnico que gestiona el menÃº, el estado y los mÃ³dulos.
- **DiseÃ±o Modular:** Cada fase principal reside en su propio mÃ³dulo `.ps1`.
- **Manejo de Errores Fiable:** Utiliza un wrapper (`Invoke-NativeCommand`) para ejecutar comandos externos, previniendo falsos positivos.
- **Registro AutomÃ¡tico:** Toda la salida de la consola se guarda en un archivo de log (`.txt`).
- **Experiencia de Usuario:** LÃ³gica de menÃº que no parpadea y barras de progreso con temporizadores fiables.

### Requisitos

- **Sistema Operativo:** Windows 10 (1809+) o Windows 11.
- **PowerShell:** VersiÃ³n 5.1 o superior.
- **Privilegios:** Se requieren derechos de Administrador (el script intentarÃ¡ auto-elevarse).

### InstalaciÃ³n

1.  Clona o descarga este repositorio en tu mÃ¡quina.
    ```bash
    git clone https://github.com/miguel-cinsfran/Fenix
    cd fenix
    ```

2.  AsegÃºrate de que la estructura de directorios se mantiene intacta.
3.  Si PowerShell restringe la ejecuciÃ³n de scripts, abre una terminal de PowerShell como Administrador y ejecuta:
    ```powershell
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process -Force
    ```

### Modo de Uso

1.  Haz clic derecho sobre `Phoenix-Launcher.ps1` y selecciona **"Ejecutar con PowerShell"**.
2.  AparecerÃ¡ una advertencia. Debes escribir `ACEPTO` para continuar.
3.  Usa el menÃº principal para seleccionar la fase que deseas ejecutar.

### Estructura del Proyecto

```text
/
â”œâ”€â”€ ðŸ“„ Phoenix-Launcher.ps1      # Orquestador principal
â”œâ”€â”€ ðŸ“„ README.md                 # Esta documentaciÃ³n
â”œâ”€â”€ ðŸ“‚ modules/
â”‚   â”œâ”€â”€ Phoenix-Utils.ps1       # Funciones de UI y utilidades compartidas
â”‚   â”œâ”€â”€ Phase1-OneDrive.ps1     # LÃ³gica para la erradicaciÃ³n de OneDrive
â”‚   â”œâ”€â”€ Phase2-Software.ps1     # LÃ³gica para la instalaciÃ³n de software
â”‚   â”œâ”€â”€ Phase3-Tweaks.ps1       # LÃ³gica para los ajustes del sistema
â”‚   â”œâ”€â”€ Phase4-WSL.ps1          # LÃ³gica para la instalaciÃ³n de WSL
â”‚   â””â”€â”€ Phase5-Cleanup.ps1      # LÃ³gica para la limpieza del sistema
â””â”€â”€ ðŸ“‚ assets/
    â”œâ”€â”€ catalog_schema.json     # Esquema JSON que define la estructura de los catÃ¡logos
    â””â”€â”€ ðŸ“‚ catalogs/
        â”œâ”€â”€ chocolatey_catalog.json # CatÃ¡logo de software para Chocolatey
        â”œâ”€â”€ winget_catalog.json     # CatÃ¡logo de software para Winget
        â”œâ”€â”€ system_tweaks.json      # CatÃ¡logo de ajustes para la Fase 3
        â””â”€â”€ system_cleanup.json     # CatÃ¡logo de tareas para la Fase 5
```

### PersonalizaciÃ³n de CatÃ¡logos

Para personalizar las operaciones, simplemente edita los archivos `.json` correspondientes en la carpeta `assets/catalogs`. Esto te permite definir quÃ© software instalar, quÃ© ajustes aplicar y quÃ© tareas de limpieza ejecutar.

### Arquitectura y LÃ³gica Interna

-   **Orquestador Central (`Phoenix-Launcher.ps1`):** No contiene lÃ³gica de aprovisionamiento. Su funciÃ³n es cargar mÃ³dulos, gestionar un objeto de estado global (`$state`) y mostrar el menÃº.
-   **MÃ³dulos de Fase (`Phase*.ps1`):** Son autocontenidos. Cada mÃ³dulo exporta una funciÃ³n principal que recibe el objeto `$state`, lo modifica y lo retorna.
-   **Objeto de Estado (`$state`):** Un objeto `[PSCustomObject]` que se pasa a travÃ©s de todas las funciones para centralizar el estado de la ejecuciÃ³n. Su carga es retrocompatible con versiones antiguas del script.
-   **Manejo de Errores:** El script se basa en la funciÃ³n `Invoke-NativeCommand` para ejecutar comandos externos de forma fiable. Este wrapper captura flujos de salida y error, y comprueba los cÃ³digos de salida y el contenido del texto para detectar fallos.
-   **Utilidades Compartidas (`Phoenix-Utils.ps1`):** Proporciona funciones comunes para la UI, asegurando una apariencia consistente y un manejo de trabajos en segundo plano fiable.

### Preguntas Frecuentes (FAQ)

<details>
<summary><strong>Â¿Es seguro ejecutar este script?</strong></summary>

El script estÃ¡ diseÃ±ado para ser seguro, pero realiza cambios importantes. Incluye varias salvaguardas:
- Requiere consentimiento explÃ­cito escribiendo "ACEPTO".
- AÃ­sla la lÃ³gica en mÃ³dulos para reducir el riesgo de efectos secundarios.
- Genera un log completo de cada operaciÃ³n.
- Utiliza un manejo de errores robusto para detenerse si algo sale mal.
</details>

<details>
<summary><strong>Â¿QuÃ© hace exactamente la "erradicaciÃ³n" de OneDrive?</strong></summary>

Es mÃ¡s que una simple desinstalaciÃ³n. El proceso incluye: detener el proceso, ejecutar los desinstaladores oficiales, eliminar tareas programadas, limpiar claves del registro y, finalmente, auditar (y opcionalmente reparar) las rutas de las carpetas personales del usuario.
</details>

### Licencia

Este proyecto se distribuye bajo la Licencia BLABLA. Consulta el archivo `LICENSE` para mÃ¡s detalles.
