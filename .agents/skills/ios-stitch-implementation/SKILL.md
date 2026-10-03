---
name: ios-stitch-implementation
description: Use when building or reviewing native SwiftUI screens from an existing ZDEEP screen in Google Stitch.
---

# Реализация native UI по Stitch

Используй этот skill для native SwiftUI экрана, который должен соответствовать экрану Stitch; он не задаёт поведение WebView или бизнесового bridge.

**REQUIRED SUB-SKILL:** Используй `stitch-design-pipeline` для чтения текущего проекта, экранов, HTML и дизайн-системы Stitch.

## Источник значений

Для ZDEEP используй `projectId: 1417382377358815087`: получи проект и нужный экран через `get_screen`. HTML и связанные с экраном theme/config — источник значений; screenshot служит только для визуального сравнения. Если `get_screen` вернул `htmlCode.downloadUrl`, прочитай HTML по URL. Если источник недоступен, остановись: не угадывай стили по картинке.

Сверяй конкретный экран с его дизайн-системой. В одном проекте Stitch могут находиться разные темы. Если экранный HTML расходится с глобальной темой проекта, не выбирай одну молча: зафиксируй конкретные спорные значения и уточни у владельца Stitch, какая тема является источником истины для будущего native UI.

## Перенос в SwiftUI

Не переводи Tailwind-классы по одному в SwiftUI modifiers. Извлеки их итоговые семантические значения из CSS/конфигурации экрана и используй общие нативные токены:

| Stitch/CSS | Общий нативный стиль |
|---|---|
| Семантические color tokens и состояния | `Color` из Asset Catalog или общего `DesignTokens` |
| Вычисленные padding/gap | Централизованные значения spacing в SwiftUI points |
| Computed `border-radius` | Общая shape/radius-константа для `RoundedRectangle` |
| Семейство, размер, вес, line-height, tracking | Типографические `Font` styles с Dynamic Type |
| Повторяющаяся кнопка/карточка/поле | Reusable `ButtonStyle`, `ViewModifier` или компонент |

Выясни версию Tailwind и overrides: `p-4`, `rounded-2xl` и другие классы зависят от настроенной шкалы. Проверяй generated CSS/тему, не выводи размер из имени класса. [Tailwind theme variables](https://tailwindcss.com/docs/theme).

CSS `px` используй как стартовое значение SwiftUI points; сверяй результат на целевом viewport/safe areas. Для custom font проверь наличие и PostScript name; `Font.custom(_:size:relativeTo:)` поддерживает Dynamic Type. Если font/fallback не найден, остановись. [Apple: custom fonts in SwiftUI](https://developer.apple.com/documentation/swiftui/applying-custom-fonts-to-text).

Не дублируй token literals в View; сохраняй состояния, семантику SwiftUI controls и accessibility.

## Пример по текущему Stitch Welcome

HTML экрана `bc93291bf18e4d78b737a9a035b30434` (label `Нативе welcome`) задаёт CTA классами `bg-text-primary text-on-primary rounded-2xl py-4 px-6 w-full`. Связанная с этим HTML-тема `Bento Grids` задаёт `text-primary = #1D1D1F` и `on-primary = #FFFFFF`; generated CSS даёт radius 16px, vertical padding 16px и horizontal padding 24px. Семантический SwiftUI вариант может выглядеть так:

```swift
Button("Сканировать QR-код", action: onScan)
    .foregroundStyle(.white)
    .padding(.vertical, 16)
    .padding(.horizontal, 24)
    .frame(maxWidth: .infinity)
    .background(
        Color(red: 29.0 / 255.0, green: 29.0 / 255.0, blue: 31.0 / 255.0),
        in: RoundedRectangle(cornerRadius: 16)
    )
```

В рабочем View значения должны идти из общих `DesignTokens`/`ButtonStyle`, а не повторяться литералами. Это значения только HTML Welcome. Глобальная система проекта `Autonomous Kinetic` сейчас DARK, `Libre Franklin`, с красным primary. До реализации экрана уточни у владельца Stitch, какая тема является источником истины.

## Сравнение результата

1. Запиши screen ID, theme и viewport.
2. Сними SwiftUI screenshot в сопоставимых состоянии, размерах и safe areas.
3. Сравни layout/типографику/цвета с HTML; исправляй общий token/component, а не отдельный класс локальными modifiers.

Проверка относится к одному CTA; полный продуктовый экран не реализован.
