# Hermes Setup

Instalador todo-en-uno para conectar [Hermes Agent](https://hermes-agent.nousresearch.com) con **Hermes Console** (la app Android).

En tu servidor (Linux con `systemd`), ejecuta:

```sh
curl -fsSL https://raw.githubusercontent.com/xP3ta/hermes-setup/main/hermes-mobile-setup.sh | sh
```

Qué hace (todo idempotente — si algo ya está en marcha, no lo toca):

1. Instala Hermes Agent si el equipo no lo tiene (sin asistente interactivo, sin navegador).
2. Genera un token de API (`API_SERVER_KEY` en `~/.hermes/.env`) si falta.
3. Arranca el gateway (`:8642`), el dashboard (`:9119`) y el Mobile Bridge (`:9131`) como servicios `systemd --user` que sobreviven a reinicios.
4. Imprime un QR y un enlace `hermes://pair?...` — escanéalo con la app y listo.

Todo escucha en tu red privada (Tailscale o LAN); no se expone nada a Internet ni se envía telemetría. Puedes leer el script completo antes de ejecutarlo: [`hermes-mobile-setup.sh`](hermes-mobile-setup.sh).

## Contenido

| Archivo | Qué es |
|---|---|
| `hermes-mobile-setup.sh` | El instalador (POSIX sh, legible de arriba abajo) |
| `hermes_bridge.py` | El Mobile Bridge que el instalador despliega en `~/.hermes/` |

## Mantenimiento

La fuente de verdad de ambos archivos vive en el repo de la app
(`scripts/hermes-mobile-setup.sh` y `assets/bridge/hermes_bridge.py`).
Al cambiar cualquiera de los dos allí, actualizar la copia de este repo:
la app enseña este mismo comando `curl` tanto en el onboarding como al
actualizar el bridge, así que este repo debe ir siempre al día con el
asset embebido en la app publicada.
