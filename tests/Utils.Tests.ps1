# Iniciar el entorno de pruebas.
# Esto asegura que podemos encontrar el módulo de utilidades relativo a la ubicación de este script.
$PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$projectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$utilsModulePath = Join-Path $projectRoot "modules/Phoenix-Utils.psm1"

# Importar las funciones que queremos probar.
Import-Module $utilsModulePath -Force

# Iniciar un bloque de descripción de Pester para agrupar pruebas relacionadas.
Describe "Request-MenuSelection" {

    BeforeEach {
        Mock Write-PhoenixStyledOutput -ModuleName 'Phoenix-Utils' { }
        Mock Start-Sleep -ModuleName 'Phoenix-Utils' { }
        Mock Write-Host -ModuleName 'Phoenix-Utils' { }
    }

    # Contexto: Pruebas para la lógica de selección de menú.
    Context "Input Parsing" {
        # Definir las opciones válidas para las pruebas.
        $validChoices = @('1', '2', '3', '4', '5', '6', '7', '8', '9', 'A', 'B', 'C')

        # Prueba para una selección numérica única.
        It "should handle a single numeric choice" {
            Mock Read-Host -ModuleName 'Phoenix-Utils' { return "2" } -Verifiable
            $result = Request-MenuSelection -ValidChoices $validChoices
            $result | Should -Be "2"
            Assert-VerifiableMocks
        }

        # Prueba para una selección de letra única.
        It "should handle a single letter choice" {
            Mock Read-Host -ModuleName 'Phoenix-Utils' { return "A" } -Verifiable
            $result = Request-MenuSelection -ValidChoices $validChoices
            $result | Should -Be "A"
            Assert-VerifiableMocks
        }

        # Prueba para múltiples selecciones separadas por comas.
        It "should handle multiple comma-separated choices" {
            Mock Read-Host -ModuleName 'Phoenix-Utils' { return "1,3,C" } -Verifiable
            $result = Request-MenuSelection -ValidChoices $validChoices -AllowMultipleSelections
            $result | Should -BeOfType ([String[]])
            $result | Should -Be @("1", "3", "C")
            Assert-VerifiableMocks
        }

        # Prueba para un rango de selecciones numéricas.
        It "should handle a numeric range" {
            Mock Read-Host -ModuleName 'Phoenix-Utils' { return "2-5" } -Verifiable
            $result = Request-MenuSelection -ValidChoices $validChoices -AllowMultipleSelections
            $result | Should -BeOfType ([String[]])
            $result | Should -Be @("2", "3", "4", "5")
            Assert-VerifiableMocks
        }

        # Prueba para una combinación de selecciones (números, rangos, letras).
        It "should handle a complex mix of choices and ranges" {
            Mock Read-Host -ModuleName 'Phoenix-Utils' { return "1, 3-5, B, 8" } -Verifiable
            $result = Request-MenuSelection -ValidChoices $validChoices -AllowMultipleSelections
            $result | Should -BeOfType ([String[]])
            # Pester's -Be check on arrays is order-sensitive, so we sort both for a reliable test.
            ($result | Sort-Object) | Should -Be ("1", "3", "4", "5", "8", "B" | Sort-Object)
            Assert-VerifiableMocks
        }

        # Prueba para ignorar opciones no válidas.
        It "should ignore invalid choices in the input" {
            # Los mocks ahora se manejan en el bloque BeforeEach para garantizar el scope correcto.

            # Simular dos entradas: la primera no válida, la segunda sí.
            $userInputs = @("X,Y,Z", "1,A")
            $inputCounter = 0
            Mock Read-Host -ModuleName 'Phoenix-Utils' { return $userInputs[$script:inputCounter++] } -Verifiable

            $result = Request-MenuSelection -ValidChoices $validChoices -AllowMultipleSelections
            $result | Should -Be @("1", "A")
            # Verificar que Read-Host fue llamado dos veces.
            (Get-Mockable -Name Read-Host).History.Count | Should -Be 2
            Assert-VerifiableMocks
        }
    }

    Context "Yes/No Prompt Normalization" {
        # Prueba para la normalización de la entrada 'S' (Sí).
        It "should normalize various 'Yes' inputs to 'S'" {
            $inputs = @("s", "S", "si", "SI", "y", "Y", "yes", "YES")
            foreach ($input in $inputs) {
                Mock Read-Host -ModuleName 'Phoenix-Utils' { return $input }
                $result = Request-MenuSelection -IsYesNoPrompt -ValidChoices @('S', 'N')
                $result | Should -Be "S"
            }
        }

        # Prueba para la normalización de la entrada 'N' (No).
        It "should normalize various 'No' inputs to 'N'" {
            $inputs = @("n", "N", "no", "NO")
            foreach ($input in $inputs) {
                Mock Read-Host -ModuleName 'Phoenix-Utils' { return $input }
                $result = Request-MenuSelection -IsYesNoPrompt -ValidChoices @('S', 'N')
                $result | Should -Be "N"
            }
        }
    }
}
