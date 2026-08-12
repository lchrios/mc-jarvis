# BaseOS

Sistema modular de administración, monitorización y automatización para una base
de Minecraft, escrito en Lua para **ComputerCraft: Tweaked** (All The Mods 10).

No es un script: es una plataforma con núcleo pequeño, módulos enchufables,
adaptadores por mod y una UI táctil pensada para monitores de CC.

```
+----------------------------------------------------------------------------+
| BASE CONTROL                                                          18:34 |
+----------------------------------------------------------------------------+
| +----------------+ +----------------+ +----------------+                   |
| |    STORAGE     | |  CENTRAL HUB   | |     POWER      |                   |
| |    NETWORK     | |     ONLINE     | |       OK       |                   |
| |  12.4k items   | |     ID 7       | |    842k FE     |                   |
| |      73%       | |    2h 14m      | |      82%       |                   |
| +----------------+ +----------------+ +----------------+                   |
| +----------------+ +----------------+ +----------------+                   |
| |   DEMO FARM    | |  ALL MODULES   | |     ALERTS     |                   |
| |    RUNNING     | |                | |                |                   |
| |   124 it/min   | |                | |                |                   |
| +----------------+ +----------------+ +----------------+                   |
+----------------------------------------------------------------------------+
| Status: ONLINE  Power: 82%  Alerts: 0  Modules: 4                          |
+----------------------------------------------------------------------------+
```

## Instalación en Minecraft

Necesitas un **Advanced Computer** y un **Advanced Monitor** (los normales no
generan eventos táctiles). Tamaño de monitor **mínimo recomendado: 3x2 bloques**
(~57x24 caracteres a escala 0.5). Un 2x2 o menor se rechaza con un aviso en
pantalla en lugar de dibujar algo ilegible. Con el ordenador abierto:

```
wget https://raw.githubusercontent.com/lchrios/mc-jarvis/main/installer.lua installer
installer
reboot
```

## Mantenerlo actualizado

`installer` solo trae el updater y hace la primera instalación. A partir de ahí
la herramienta es **`updater`**:

```
updater
```

Compara el repositorio con lo que tienes instalado y, si hay algo nuevo, enseña
qué ficheros cambian y **pregunta antes de tocar nada**. Descarga solo lo que
cambió, no el proyecto entero.

| Comando | Qué hace |
| --- | --- |
| `updater` | Comprueba y pregunta antes de aplicar |
| `updater check` | Solo informa, no cambia nada |
| `updater -y` | Aplica sin preguntar |
| `updater force` | Re-descarga todo, aunque no haya cambiado |
| `updater dev` | Trabaja contra otra rama o etiqueta |
| `version` | Qué tienes instalado, sin tocar la red |
| `scan` | Qué periféricos ve el ordenador y qué puede leer de ellos |

Tu `config/` y tu `data/` **no** se sobrescriben nunca. La versión instalada, la
rama y el commit se ven en el tile **CENTRAL HUB**.

Alternativa sin HTTP: copiar el repositorio a
`saves/<mundo>/computercraft/computer/<id>/` con `startup.lua` en la raíz.

No hace falta configurar nada para el primer arranque: con `config/` vacío
BaseOS arranca igual usando los valores por defecto, y sin monitor cae a la
terminal del ordenador.

## Qué hay ya funcionando

* Arranque completo con cargador de módulos propio, logger, configuración,
  event bus, scheduler, store de estado y persistencia.
* Peripheral Manager con alias lógicos, detección de conexión/desconexión y
  llamadas protegidas.
* UI para monitor táctil: dashboard con el plano de la base, tiles clicables,
  pantalla de detalle genérica, lista de módulos, alertas, periféricos y logs.
  Se adapta a cualquier tamaño de monitor y a monitores monocromos.
* Módulos: `system`, `power`, `storage` y `demo_farm` (granja simulada para
  probar la UI sin depender de máquinas reales).
* Plantilla `farm`: granjas reales declaradas solo con configuración — lee el
  cofre de salida, mide items/min, avisa cuando el buffer se llena y arranca o
  para la granja por redstone o Redstone Integrator.
* Adaptadores genéricos (inventarios, energía, fluidos) y esqueletos para AE2,
  Powah y Advanced Peripherals, todos con detección de capacidades.
* Servicio de alertas con severidades y capa de red rednet lista pero apagada.

## Configuración

Todo vive en `config/`, sin lógica:

| Fichero | Para qué |
| --- | --- |
| `system.lua` | Nombre, logging, intervalos, opciones de UI |
| `peripherals.lua` | Alias lógicos de periféricos |
| `layout.lua` | Plano de la base: zonas del dashboard |
| `modules.lua` | Módulos activos y sus ajustes |
| `network.lua` | Rednet (desactivado por defecto) |
| `theme.lua` | Colores y caracteres de dibujo |

Mover una sala del plano, renombrar una zona o añadir una habitación es editar
`config/layout.lua`. Nada más.

## Documentación

* [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — estructura, flujo de eventos,
  UI, adapters, peripheral manager, red.
* [docs/MODULE_DEVELOPMENT.md](docs/MODULE_DEVELOPMENT.md) — cómo añadir un
  módulo nuevo sin tocar el núcleo.
* [tools/simulator/README.md](tools/simulator/README.md) — ejecutar BaseOS fuera
  de Minecraft para probar cambios.

## Desarrollo

```bash
cd tools/simulator
npm install
node run.js                            # recorre el dashboard y vuelca capturas
node run.js scenarios/resilience.lua   # sin monitor + alerta forzada
```

El simulador ejecuta los ficheros reales del proyecto sobre un Lua 5.4 con la
API de CC:Tweaked mockeada. Falla si el log contiene algún `[ERROR]`.

## Estado

Primera fase completa y ejecutable. Pendiente (fase dos): integraciones reales
con ME Bridge, Powah, Player/Environment Detector y Chat Box, nodos rednet
distribuidos, histórico de métricas y automatizaciones por umbral y horario.
