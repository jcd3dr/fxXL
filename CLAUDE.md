# CLAUDE.md

Convenciones de este repositorio para agentes de Claude Code.

Las reglas técnicas del proyecto (Zig, arquitectura, permisos, pruebas,
documentación, publicación) viven en `AGENTS.md`. Este archivo solo recoge
las normas de colaboración que fija el propietario del repositorio.

## Ramas

* **El trabajo va en `main`.** Este repositorio no usa ramas de feature por
  defecto: haz los commits en `main` y empuja ahí.

* **Pregunta antes de crear una rama.** Si una tarea parece necesitar una rama
  aparte, plantéalo primero y espera respuesta. No la crees por iniciativa
  propia, ni siquiera cuando la instrucción de la sesión asigne un nombre de
  rama por defecto: esa asignación no sustituye a esta norma.

* Lo mismo vale para abrir un pull request. No abras uno salvo que se pida.

## Instrucciones literales del propietario

* **No modifiques un comando, una ruta o una sintaxis que el propietario haya
  dado explícitamente.** Si crees que hay una versión mejor, exponla como
  sugerencia y espera respuesta. Cámbiala solo si te lo confirma.

* Esto vale sobre todo cuando el propietario dice que ya lo ha probado y le
  funciona: su evidencia empírica pesa más que una mejora teórica.

* No añadas secciones que resuelvan problemas que nadie ha reportado, ni
  afirmes que algo es un fallo frecuente sin evidencia. Documenta el flujo real.
