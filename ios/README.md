# Ваджра — iOS

Нативный порт `../vajra-tracker.html` (v2.8.1): SwiftUI, iOS 18+, без SwiftData.
Данные — тот же сервер `life.maxdzhabali.com/vajra/api` (`life-chronicle/personal_apps.py`), вход паролем Life
(POST `/chronicle/login`, `pw`, `next=/vajra/` → кука `life`).

Плюсы натива: интент «Памятование +1» (Siri, кнопка Action, Шорткаты), кнопка «+1» в Пункте управления
и на экране блокировки (ControlWidget), виджеты со счётом дня (круглый/прямоугольный на экране блокировки,
маленький с кнопкой +1).

## Собрать (на Mac mini — там Xcode)

```bash
cd ios
xcodegen generate                      # → Vajra.xcodeproj (в git не хранится)
xcodebuild -project Vajra.xcodeproj -scheme Vajra -sdk iphoneos -destination generic/platform=iOS \
  -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO build
xcodebuild test -project Vajra.xcodeproj -scheme Vajra \
  -destination "platform=iOS Simulator,name=<iPhone>" -derivedDataPath build/dd
```

Демо без сети: аргумент запуска `-demo` (локальные данные во временной папке), вкладка — `-tab calendar|sleep`.

Иконка-заглушка: `tools/make_icon.sh` (из `../icon-512.png`, 1024 без альфы).

## Таргеты и подпись

| Таргет | Bundle ID |
|---|---|
| Vajra (приложение, «Ваджра») | `com.maxdzhabali.vajra` |
| VajraWidgets (WidgetKit + ControlWidget) | `com.maxdzhabali.vajra.widgets` |

Оба — в App Group `group.com.maxdzhabali.vajra`. Team `F8H3UK3UF7`, подпись в проекте Automatic.
Для TestFlight нужны ДВА профиля App Store (приложение + расширение) — имена в `tools/ExportOptions.plist`
(«Vajra App Store», «Vajra Widgets App Store»); `PROVISIONING_PROFILE_SPECIFIER` задавать по таргету, не глобально.
Схема как у ShamaTimer: см. `../../shamatimer/ios/README.md` и `tools/asc.py` там.

## Что где

- `Shared/` — компилируется в оба таргета: модель слотов (`norm_slots`/`merge_slots` 1-в-1 с сервером),
  статистика, хранилище дней (`DayStore`: JSON на день в App Group, межпроцессный flock, флаг `dirty`),
  API + синк, интент `IncrementRecollectionIntent`.
- `Vajra/` — приложение: вход, `AppModel` (логика экрана, debounce синка 1,5 с, опрос 20 с), экраны.
- `VajraWidgets/` — виджеты и ControlWidget.
- `VajraTests/` — слияние слотов (ожидания из Python), даты/полночь, статистика, интент на временном каталоге.

Синк: каждая правка — операция с UUID в очереди дня (`add` для ±1 и оценок, `set` по полям для
Сон/Забыл/Сброса). Отправка — `POST /vajra/api/days/<дата>/ops?ops=1`: сервер применяет идемпотентно по id
(повтор после потерянного ответа безопасен), ответ = снимок дня. Показ = снимок + ожидающие операции,
кроме уже применённых (`applied_tail`). Нужен серверный патч `vajra_ops` (life-chronicle/personal_apps.py) —
без него приложение не синкается. Кука `life` — в общем cookie-хранилище App Group и копией в его
UserDefaults, поэтому расширение тоже отправляет «+1» сразу (таймаут 5 с), иначе дошлёт приложение.

TestFlight: `tools/upload.sh` на mini (профили заданы по таргетам в project.yml, Release).

## Банк воззрений и пинги

Банк (`{version, views:[{id,text,tag}], prompts:[{id,q,hint,tag}]}`) лежит только на сервере —
`/srv/life/apps/vajra/bank.json`, отдаётся `GET /vajra/api/bank` за входом Life; источник — закрытая страница
в dharma wiki. **В репозитории текстов банка нет** (тесты и демо — нейтральные строки). Приложение грузит банк
при входе, при запуске и не чаще раза в 12 ч, кэш — `bank.json` в контейнере App Group (`Shared/Bank.swift`).

- **Карточка воззрения** над главной кнопкой: одна фраза из `views`, меняется после засчитанного +1 (удержанием;
  +5 не меняет), при открытии и по тапу. Порядок — «мешок» без повторов, состояние в UserDefaults группы.
  Без банка карточка скрыта; выключается в настройках (шестерёнка в шапке).
- **Пинги** (`Vajra/Pings/Pings.swift`, по умолчанию выкл): N в день (1–12) в случайные моменты окна
  (08:00–21:00), ≥ 45 мин между, на 7 дней вперёд, ≤ 50 в очереди; пересоздаются при запуске, возврате,
  смене настроек, после ответа и через BGAppRefreshTask (~12 ч). Заголовок — `q`, текст — `hint`
  (без банка — «Что сейчас перед тобой?»). Действие «Вспомнил +1» работает с экрана блокировки:
  add {count 1} в слот момента ответа + попытка отправки. Тап по пингу — просто открыть приложение.

- **Виджет «Цитата»** (`VajraWidgets`): экран блокировки — выдержка ≤ 90 знаков; маленький/StandBy — ≤ 110 + источник;
  средний «Домой» — ≤ 160 + источник, счёт дня и «+1». Цитата выбирается детерминированно по (дата, 15-мин слот)
  из кэша банка (`QuotePick`), мешок карточки не трогает. Без банка — «Открой Ваджру, чтобы загрузить выдержки».
- **«Не гасить экран»** (по умолчанию вкл): пока приложение открыто, `isIdleTimerDisabled = true`.

Демо-скриншоты: `-demo` (нейтральный банк), `-noOffer` — без плашки пингов, `-settings` — сразу лист настроек.
