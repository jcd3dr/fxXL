# fx en Windows 11 con WSL

Guía para usar `fx` desde PowerShell sobre carpetas nativas de Windows.

## Introducción

`fx` está escrito en Zig, un lenguaje que soporta Windows perfectamente, pero
el programa habla directamente con APIs que solo existen en Unix: el modo raw
del terminal (`termios`), los grupos de procesos, las señales POSIX y los
permisos de archivo en octal. Por eso hoy no hay un binario nativo de Windows.

Eso no te obliga a mover tu trabajo. Windows Subsystem for Linux ejecuta el
binario de Linux, y Windows monta tus discos dentro de esa máquina, de modo que
`D:\dev\mi-proyecto` es visible desde Linux como `/mnt/d/dev/mi-proyecto`. Si
además envuelves la llamada en una función de PowerShell, escribes `fx` en tu
terminal de siempre, dentro de tus carpetas de siempre, y la frontera
desaparece.

El resultado se comporta como una herramienta nativa:

```powershell
PS D:\dev\mi-proyecto> fx ask "explica los cambios de este repositorio"
```

Nada se copia, nada se sincroniza. `fx` lee y escribe los mismos archivos que
abres con VS Code o el Explorador de Windows.

### Cómo encajan las piezas

```
PowerShell (Windows)          WSL (Linux)
──────────────────────        ─────────────────────────
D:\dev\mi-proyecto  ────────► /mnt/d/dev/mi-proyecto
     │                              │
     │  function fx { ... }         │
     └──────── wsl.exe ────────────►└─ ~/.fx/bin/fx
```

`wsl.exe` traduce el directorio actual automáticamente, así que `fx` arranca ya
situado en la carpeta correcta. Es exactamente lo mismo que abrir WSL en esa
carpeta y escribir `fx`, solo que sin el paso intermedio.

---

## Paso 1: Instalar fx dentro de WSL

Si aún no tienes WSL, instálalo desde PowerShell **como administrador** y
reinicia cuando lo pida:

```powershell
wsl --install -d Ubuntu
```

Abre la terminal de Ubuntu e instala `fx` con el método oficial de Linux:

```bash
curl -fsSL https://fx.sh/setup.sh | bash
```

Cierra y vuelve a abrir la terminal de WSL para que el `PATH` se recargue, y
comprueba que responde:

```bash
fx --version
```

> **Nota:** instala `fx` *dentro* de WSL, no en Windows. El binario es de Linux
> y solo se ejecuta ahí.

---

## Paso 2: Obtener la ruta exacta del ejecutable

La función de PowerShell necesita la ruta absoluta del binario. No la adivines:
pregúntasela al sistema. Dentro de la terminal de WSL:

```bash
which fx
```

Verás una ruta como una de estas, según cómo se haya instalado:

```
/home/tu_usuario/.fx/bin/fx
/home/tu_usuario/.local/bin/fx
```

Copia la línea completa tal cual; la necesitas en el paso siguiente.

> **Por qué importa:** `wsl.exe` ejecuta el comando sin cargar tu shell de
> inicio de sesión, así que el `PATH` de tu `.bashrc` no está disponible. Si
> escribieras solo `wsl fx`, obtendrías `command not found`. La ruta absoluta
> evita ese problema por completo.

---

## Paso 3: Crear la función contenedora en PowerShell

Abre **PowerShell en Windows** (no la terminal de WSL) y crea tu archivo de
perfil si todavía no existe:

```powershell
New-Item -Path $PROFILE -ItemType File -Force
```

Ábrelo en el Bloc de notas:

```powershell
notepad $PROFILE
```

Añade esta función, sustituyendo la ruta por la que copiaste en el paso 2:

```powershell
function fx { wsl "/home/tu_usuario/.fx/bin/fx" $args }
```

Guarda, cierra, y recarga el perfil en la sesión actual:

```powershell
. $PROFILE
```

Comprueba que funciona:

```powershell
fx --version
```

### Qué hace cada parte

| Fragmento | Función |
| --- | --- |
| `wsl` | Invoca `wsl.exe`, el puente hacia Linux |
| `/home/.../fx` | Ruta absoluta del binario dentro de WSL |
| `$args` | Reenvía a `fx` todo lo que escribas después del comando |

`wsl.exe` hereda el directorio actual de Windows y lo traduce solo, así que
`fx` arranca ya situado en tu carpeta de proyecto. No hace falta indicárselo.

---

## Paso 4: Habilitar la ejecución de scripts

Si al recargar el perfil aparece este error:

```
No se puede cargar el archivo ... porque la ejecución de scripts está
deshabilitada en este sistema.
```

es la política de seguridad de PowerShell, que por defecto bloquea todos los
scripts locales. Habilítala solo para tu usuario:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

Confirma con `S` (o `Y`) cuando lo pida, y vuelve a cargar el perfil:

```powershell
. $PROFILE
```

**`RemoteSigned` es la opción correcta aquí:** permite ejecutar los scripts que
tú escribes en tu equipo, pero sigue exigiendo firma digital a cualquier script
descargado de internet. No necesitas `Unrestricted`, y `-Scope CurrentUser` no
requiere permisos de administrador ni afecta al resto del sistema.

Para ver en qué estado quedó:

```powershell
Get-ExecutionPolicy -Scope CurrentUser
```

---

## Paso 5: Configurar las credenciales

No hay nada especial que hacer por estar en Windows. `fx` se ejecuta dentro de
WSL, con el mismo usuario y el mismo `HOME` que si abrieras la terminal de
Ubuntu a mano, así que lee su configuración de `~/.fx/` con normalidad.

Configúralas una vez, desde la terminal de WSL, como en cualquier Linux:

```bash
fx login              # Vercel AI Gateway
fx login compat       # endpoint compatible con OpenAI (OpenRouter, etc.)
```

A partir de ahí, la función de PowerShell las encuentra sola.

---

## Paso 6: Flujo de trabajo diario

Ya no hay nada especial que recordar. Abre PowerShell, entra en tu proyecto de
Windows y trabaja:

```powershell
cd D:\dev\mi-proyecto
fx --help
```

Una consulta puntual:

```powershell
fx ask "resume la arquitectura de este proyecto"
```

La sesión interactiva:

```powershell
fx
```

Y el resto de comandos, igual que en Linux:

```powershell
fx models
fx status
fx sessions
```

Todos operan sobre `D:\dev\mi-proyecto`. Los archivos que `fx` edita son los
mismos que ves en el Explorador y en tu editor, sin copias ni sincronización.

---

## Limitaciones y ajustes

Conviene conocerlas antes de que te sorprendan.

### El rendimiento sobre `/mnt/` es menor

WSL2 accede a los discos de Windows a través de una capa de traducción, y eso
tiene un coste real. Un agente de codificación lee muchos archivos y hace
muchas búsquedas, así que la diferencia se nota en proyectos grandes.

Si un repositorio te resulta lento, la solución es moverlo al sistema de
archivos de Linux, donde la velocidad es nativa:

```bash
# dentro de WSL
mv /mnt/d/dev/proyecto-grande ~/dev/proyecto-grande
```

Desde Windows sigue siendo accesible en el Explorador con la ruta
`\\wsl$\Ubuntu\home\tu_usuario\dev\proyecto-grande`, y VS Code lo abre de forma
nativa con la extensión **WSL**. Pierdes la comodidad de `D:\`, pero ganas
bastante velocidad.

### No pases rutas de Windows como argumentos

`fx` corre dentro de Linux y no entiende `D:\dev\archivo.txt`. Usa rutas
relativas, que funcionan siempre:

```powershell
fx ask "revisa src\main.zig"     # correcto: relativa al directorio actual
fx ask "revisa D:\dev\x\main.zig"  # incorrecto: fx no puede resolverla
```

### Los finales de línea

Git puede introducir finales de línea CRLF al trabajar entre los dos sistemas.
Si ves diferencias fantasma en archivos que no tocaste, configúralo dentro de
WSL:

```bash
git config --global core.autocrlf input
```

### Actualizar fx

Las actualizaciones se hacen dentro de WSL, como cualquier otra herramienta de
Linux:

```bash
fx upgrade
```

Tu función de PowerShell no necesita cambios: apunta a una ruta fija que el
actualizador respeta.

---

## Solución de problemas

| Síntoma | Causa y solución |
| --- | --- |
| `command not found` al ejecutar `fx` | La ruta de la función es incorrecta. Vuelve al paso 2 y usa la salida exacta de `which fx` |
| El perfil no se carga al abrir PowerShell | Política de ejecución. Aplica el paso 4 |
| `fx` no encuentra las credenciales | Ejecuta `fx login` dentro de la terminal de WSL. Ver el paso 5 |
| Los acentos o los caracteres de dibujo se ven mal | Usa **Windows Terminal**, no la consola clásica `conhost` |
| Todo va lento en un proyecto grande | Es el acceso a `/mnt/`. Considera mover el repositorio al disco de Linux |

Para verificar que la traducción de rutas funciona, comprueba desde dentro
dónde cree `fx` que está:

```powershell
cd D:\dev\mi-proyecto
wsl pwd
# Debe imprimir: /mnt/d/dev/mi-proyecto
```

Si esa línea es correcta, la integración está bien montada.
