# Iniciar el entorno de pruebas.
# Esto asegura que podemos encontrar el mÃ³dulo de utilidades relativo a la ubicaciÃ³n de este script.
$PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$projectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$utilsModulePath = Join-Path $projectRoot "modules/Phoenix-Utils.psm1"

# Importar las funciones que queremos probar.
. $utilsModulePath

# Iniciar un bloque de descripciÃ³n de Pester para agrupar pruebas relacionadas.
Describe "Request-MenuSelection" {

    # Contexto: Pruebas para la lÃ³gica de selecciÃ³n de menÃº.
    Context "Input Parsing" {
        # Definir las opciones vÃ¡lidas para las pruebas.
        $validChoices = @('1', '2', '3', '4', '5', '6', '7', '8', '9', 'A', 'B', 'C')

        # Prueba para una selecciÃ³n numÃ©rica Ãºnica.
        It "should handle a single numeric choice" {
            Mock Read-Host { return "2" } -Verifiable
            $result = Request-MenuSelection -ValidChoices $validChoices
            $result | Should -Be "2"
            Assert-VerifiableMocks
        }

        # Prueba para una selecciÃ³n de letra Ãºnica.
        It "should handle a single letter choice" {
            Mock Read-Host { return "A" } -Verifiable
            $result = Request-MenuSelection -ValidChoices $validChoices
            $result | Should -Be "A"
            Assert-VerifiableMocks
        }

        # Prueba para mÃºltiples selecciones separadas por comas.
        It "should handle multiple comma-separated choices" {
            Mock Read-Host { return "1,3,C" } -Verifiable
            $result = Request-MenuSelection -ValidChoices $validChoices -AllowMultipleSelections
            $result | Should -BeOfType ([String[]])
            $result | Should -Be @("1", "3", "C")
            Assert-VerifiableMocks
        }

        # Prueba para un rango de selecciones numÃ©ricas.
        It "should handle a numeric range" {
            Mock Read-Host { return "2-5" } -Verifiable
            $result = Request-MenuSelection -ValidChoices $validChoices -AllowMultipleSelections
            $result | Should -BeOfType ([String[]])
            $result | Should -Be @("2", "3", "4", "5")
            Assert-VerifiableMocks
        }

        # Prueba para una combinaciÃ³n de selecciones (nÃºmeros, rangos, letras).
        It "should handle a complex mix of choices and ranges" {
            Mock Read-Host { return "1, 3-5, B, 8" } -Verifiable
            $result = Request-MenuSelection -ValidChoices $validChoices -AllowMultipleSelections
            $result | Should -BeOfType ([String[]])
            # Pester's -Be check on arrays is order-sensitive, so we sort both for a reliable test.
            ($result | Sort-Object) | Should -Be ("1", "3", "4", "5", "8", "B" | Sort-Object)
            Assert-VerifiableMocks
        }

        # Prueba para ignorar opciones no vÃ¡lidas.
        It "should ignore invalid choices in the input" {
            # Mock de Write-Host para que no imprima los mensajes de error en la consola durante la prueba.
            Mock Write-Host { }
            Mock Write-PhoenixStyledOutput { }
            Mock Start-Sleep { }

            # Simular dos entradas: la primera no vÃ¡lida, la segunda sÃ­.
            $userInputs = @("X,Y,Z", "1,A")
            $inputCounter = 0
            Mock Read-Host { return $userInputs[$script:inputCounter++] } -Verifiable

            $result = Request-MenuSelection -ValidChoices $validChoices -AllowMultipleSelections
            $result | Should -Be @("1", "A")
            # Verificar que Read-Host fue llamado dos veces.
            (Get-Mockable -Name Read-Host).History.Count | Should -Be 2
            Assert-VerifiableMocks
        }
    }

    Context "Yes/No Prompt Normalization" {
        # Prueba para la normalizaciÃ³n de la entrada 'S' (SÃ­).
        It "should normalize various 'Yes' inputs to 'S'" {
            $inputs = @("s", "S", "si", "SI", "y", "Y", "yes", "YES")
            foreach ($input in $inputs) {
                Mock Read-Host { return $input }
                $result = Request-MenuSelection -IsYesNoPrompt -ValidChoices @('S', 'N')
                $result | Should -Be "S"
            }
        }

        # Prueba para la normalizaciÃ³n de la entrada 'N' (No).
        It "should normalize various 'No' inputs to 'N'" {
            $inputs = @("n", "N", "no", "NO")
            foreach ($input in $inputs) {
                Mock Read-Host { return $input }
                $result = Request-MenuSelection -IsYesNoPrompt -ValidChoices @('S', 'N')
                $result | Should -Be "N"
            }
        }
    }
}
