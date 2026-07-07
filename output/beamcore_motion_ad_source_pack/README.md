# Beamcore Motion Ad Source Pack

Пакет исходников для motion-рекламы Beamcore Agent в Premiere Pro.

## Что внутри

- `assets/png/` — PNG-оверлеи: терминал, cache hit, mesh, CTA, feature cards.
- `assets/svg/` — SVG mark логотипа.
- `footage/` — стоп-кадры из твоего видео для референса/превью. Сам оригинальный MOV не кладу в zip, потому что он большой; в Premiere используй исходный `IMG_0900.MOV`.
- `sfx/` — процедурные whoosh/ping/click/hit без copyright.
- `premiere/` — prompt для Codex через Premiere MCP + JSON таймлайн.
- `docs/` — тексты и факты из README, которые можно безопасно использовать в рекламе.

## Быстрый запуск

1. Распакуй zip рядом с проектом Premiere.
2. Убедись, что исходное видео `IMG_0900.MOV` доступно Codex/Premiere.
3. Открой `premiere/CODEX_PREMIERE_MCP_PROMPT.md` и полностью вставь в Codex.
4. Попроси Codex собрать sequence по `premiere/timeline_16x9_30s.json`.
5. Для вертикального шортса используй `premiere/timeline_9x16_30s.json` и `assets/png/poster_9x16.png` как референс.

## Важное

Фраза `99% CACHE HIT` оставлена как campaign claim от владельца проекта. В README я не увидел отдельного подтверждения именно этой цифры, поэтому в промпте есть аккуратная пометка `project claim — replace with benchmark if needed`.

Графика сделана процедурно: без AI-фото, без стоковых роботов и без типичного “нейрослопа”.
