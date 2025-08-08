# Fénix Provisioning Engine - Central Configuration File
@{
    # Rutas relativas a la raíz del proyecto.
    Paths = @{
        Modules = "modules"
        Assets = "assets"
        Logs = "logs"
        Themes = "assets/themes"
        Catalogs = "assets/catalogs"
        VscodeConfig = "assets/configs/Microsoft.VisualStudioCode"
    }

    # Nombres de ficheros de configuración y catálogos.
    FileNames = @{
        Theme = "default.json"
        TweaksCatalog = "system_tweaks.json"
        CleanupCatalog = "system_cleanup.json"
        ChocolateyCatalog = "chocolatey_catalog.json"
        WingetCatalog = "winget_catalog.json"
        VscodeExtensions = "extensions.json"
        LogBaseName = "Provision-Log-Phoenix"
    }
}
