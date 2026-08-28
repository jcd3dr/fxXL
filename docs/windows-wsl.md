# 🪟 Guía de Configuración para Windows 11 (Vía WSL + PowerShell)

Aunque `fx` fue diseñado nativamente para entornos Unix (macOS y Linux) debido a su arquitectura en Zig, puedes utilizarlo en Windows 11 de forma 100% transparente.

Con esta configuración podrás mantener todos tus proyectos en tus carpetas normales de Windows (por ejemplo, en `D:\dev\`) y ejecutar comandos de `fx` directamente desde PowerShell, sin necesidad de mudar tus archivos dentro de la máquina virtual de Linux.

## Paso 1: Instalación en WSL

Primero, asegúrate de tener activado WSL (Windows Subsystem for Linux) con tu distribución preferida (como Ubuntu). Abre la terminal de WSL e instala `fx` siguiendo el método oficial para Linux descrito en la sección [Install](../README.md#install) de este repositorio.

## Paso 2: Obtener la ruta exacta del binario

Dentro de tu terminal de WSL, ejecuta el siguiente comando para averiguar dónde se guardó el ejecutable:

```bash
which fx
```

Verás una ruta en la pantalla similar a esta: `/home/tu_usuario/.local/bin/fx` (o similar). Copia esa ruta por completo.

## Paso 3: Crear una función nativa en PowerShell

Para poder invocar el programa desde Windows como si fuera una aplicación nativa, crearemos un alias permanente en tu perfil de PowerShell.

1. Abre PowerShell en Windows y ejecuta el siguiente comando para crear y abrir tu archivo de configuración personalizada:

```powershell
New-Item -Path $PROFILE -Type File -Force; notepad $PROFILE
```

2. En el Bloc de notas que se acaba de abrir, pega la siguiente función (reemplazando la ruta de ejemplo por la ruta exacta que obtuviste en el Paso 2):

```powershell
function fx { wsl "/home/tu_usuario/.local/bin/fx" $args }
```

3. Guarda el archivo (`Ctrl + S`) y cierra el Bloc de notas.

## Paso 4: Habilitar las políticas de ejecución

Por seguridad, Windows 11 bloquea la carga de perfiles personalizados por defecto. Para permitir que tu nueva función se ejecute, corre este comando en tu PowerShell:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

(Cuando te pregunte si estás seguro, presiona la tecla `S` para confirmar y luego `Enter`).

## Paso 5: Recargar y listo

Para aplicar los cambios sin cerrar tu terminal actual, ejecuta:

```powershell
. $PROFILE
```

## 🚀 Flujo de Trabajo Diario

¡Eso es todo! Ahora puedes navegar a cualquiera de tus discos duros o carpetas de desarrollo en Windows y llamar a la IA directamente.

Por ejemplo, si tus proyectos están en `D:\dev`, simplemente haz:

```powershell
cd D:\dev\tu-proyecto-ia
fx --help
```

WSL procesará el comando tras bambalinas a la velocidad extrema de Zig, pero leerá, analizará y modificará los archivos que viven de manera segura en tu sistema de archivos de Windows 11.
