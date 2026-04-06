# MTG Installer

Простой bash-скрипт для установки, удаления и управления `mtg` через Docker.

Upstream-проект: `https://github.com/9seconds/mtg`

## Что делает

- устанавливает Docker и Docker Compose, если их ещё нет
- разворачивает `mtg` в контейнере `nineseconds/mtg:2`
- генерирует секрет через штатную команду `mtg generate-secret --hex`
- автоматически создаёт минимальный конфиг `mtg.toml`
- публикует порт `443`
- показывает `tg://proxy` и `https://t.me/proxy` ссылки через `mtg access`
- умеет полностью удалить сервис

## Требования

- Ubuntu / Debian
- root / `sudo`
- свободный порт `443`
- установленный `curl`

## Установка

Вставь в консоль с root-правами:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/whytetris/install_telemt/main/install_telemt.sh)
```
