@echo off
rem Este script de conveniencia lanza el motor Fénix en modo de depuración de UI.
rem Facilita las pruebas rápidas sin necesidad de escribir parámetros en la consola.
rem El comando 'pause' se añade para mantener la ventana abierta en caso de error fatal.
powershell.exe -ExecutionPolicy Bypass -File "%~dp0Phoenix-Launcher.ps1" -DebugUI
pause