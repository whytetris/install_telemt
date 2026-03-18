# TeleMT Installer

Простой bash-скрипт для установки, удаления и управления **TeleMT** с маскировкой через Docker.

## Что делает

- устанавливает Docker и Docker Compose (если они не установлены)
- разворачивает TeleMT в контейнере
- автоматически создаёт конфиг `telemt.toml`
- публикует порт `443`
- показывает `tg://proxy` ссылку из логов
- умеет полностью удалять сервис

## Требования

- Ubuntu / Debian
- root / `sudo`
- свободный порт `443`
- установленный `curl`

## Установка

Вставь в консоль с root правами:

```bash <(curl -fsSL https://raw.githubusercontent.com/whytetris/install_telemt/main/install_telemt.sh)```
