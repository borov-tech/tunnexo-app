# Tunnexo

Приложение VPN-сервиса Tunnexo для Windows (Android — позже).

Основано на [FlClashX](https://github.com/pluralplay/FlClashX) (ядро mihomo),
распространяется по лицензии **GNU GPL-3.0** — см. файл [LICENSE](LICENSE).
Благодарим авторов FlClashX и FlClash.

## Изменения относительно FlClashX

- название, значки и установщик Tunnexo;
- тёмная тема и фирменный цвет по умолчанию;
- данные приложения хранятся отдельно: `%APPDATA%\Tunnexo\Tunnexo`;
- служба-помощник `TunnexoHelperService` (порт 47893) — не конфликтует с FlClashX;
- в установщик встроены библиотеки Microsoft Visual C++ (msvcp140 и др.);
- проверка обновлений смотрит на релизы этого репозитория.

## Сборка

GitHub Actions → **build-windows** → *Run workflow*. Готовый установщик — в разделе
*Artifacts* запуска (`Tunnexo-windows-amd64-setup.exe`).
Тег `vX.Y.Z` собирает и прикрепляет установщик к Release.
