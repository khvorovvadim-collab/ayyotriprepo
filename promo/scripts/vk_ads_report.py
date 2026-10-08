#!/usr/bin/env python3
"""Отчёты по выгрузкам VK Рекламы и дневному логу релиза. Только стандартная библиотека.

Тип входного файла определяется автоматически:
  *.xlsx с колонкой «Возраст»  -> разбивка по полу и возрасту
  *.xlsx с колонкой «Регион»   -> разбивка по городам
  *.csv (daily_log.csv)        -> дневная динамика и инкрементальная цена добавления

Примеры:
  python promo/scripts/vk_ads_report.py promo/vremya-rtut/data/vk-ads/adGroup_demography_01.09.2026-08.10.2026.xlsx
  python promo/scripts/vk_ads_report.py promo/vremya-rtut/data/vk-ads/adGroup_geo_01.09.2026-08.10.2026.xlsx --top 15
  python promo/scripts/vk_ads_report.py promo/vremya-rtut/daily_log.csv --baseline 2026-10-01:2026-10-07 --test 2026-10-09:2026-10-15
"""

import argparse
import csv
import math
import sys
import zipfile
import xml.etree.ElementTree as ET
from collections import defaultdict
from datetime import date

NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"

# Пороги цены добавления, ₽. 50 ₽ — KPI из публичного кейса Growth Market (VK Реклама, 2024).
SCALE_MAX_CPA_ADD = 25.0
HOLD_MAX_CPA_ADD = 50.0


def read_xlsx_rows(path):
    with zipfile.ZipFile(path) as z:
        shared = []
        if "xl/sharedStrings.xml" in z.namelist():
            root = ET.fromstring(z.read("xl/sharedStrings.xml"))
            for si in root.iter(NS + "si"):
                shared.append("".join(t.text or "" for t in si.iter(NS + "t")))
        sheet = sorted(n for n in z.namelist() if n.startswith("xl/worksheets/sheet"))[0]
        root = ET.fromstring(z.read(sheet))
    rows = []
    for row in root.iter(NS + "row"):
        values = []
        for cell in row.findall(NS + "c"):
            v = cell.find(NS + "v")
            kind = cell.get("t")
            if kind == "s" and v is not None:
                values.append(shared[int(v.text)])
            elif kind == "inlineStr":
                values.append("".join(t.text or "" for t in cell.iter(NS + "t")))
            else:
                values.append(v.text if v is not None else "")
        rows.append([x.strip() for x in values])
    return rows


def num(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def split_blocks(rows):
    """Выгрузка может содержать несколько групп объявлений подряд, каждая со своим заголовком."""
    blocks = []
    current = None
    header = None
    for row in rows:
        if not row or not any(row):
            continue
        first = row[0]
        if first == "ID группы":
            current = {"id": row[1] if len(row) > 1 else "", "name": "", "rows": []}
            blocks.append(current)
            header = None
        elif first == "Название группы" and current is not None:
            current["name"] = row[1] if len(row) > 1 else ""
        elif "Результат" in row and "Показы" in row:
            header = row
            if current is None:
                current = {"id": "", "name": "", "rows": []}
                blocks.append(current)
            current["header"] = header
        elif header is not None and current is not None:
            if first.startswith("Итого"):
                current["total"] = dict(zip(header, row))
                header = None
            else:
                current["rows"].append(dict(zip(header, row)))
    return [b for b in blocks if "header" in b]


def cpa(spend, results):
    return spend / results if results else float("nan")


def fmt(x, digits=2):
    if x != x:
        return "—"
    return f"{x:,.{digits}f}".replace(",", " ")


def print_table(headers, rows):
    widths = [max(len(str(h)), *(len(str(r[i])) for r in rows)) for i, h in enumerate(headers)]
    line = "  ".join(str(h).ljust(w) for h, w in zip(headers, widths))
    print(line)
    print("-" * len(line))
    for r in rows:
        print("  ".join(str(c).rjust(w) if i else str(c).ljust(w) for i, (c, w) in enumerate(zip(r, widths))))


def report_demography(block):
    spend_key = "Потрачено, ₽"
    data = []
    for r in block["rows"]:
        if r.get("Результат", "-") == "-":
            continue
        data.append(
            {
                "age": r["Возраст"],
                "sex": r["Пол"],
                "spend": num(r.get(spend_key)),
                "res": num(r.get("Результат")),
                "imp": num(r.get("Показы")),
                "clk": num(r.get("Клики")),
            }
        )
    total_spend = sum(d["spend"] for d in data)
    total_res = sum(d["res"] for d in data)
    total_imp = sum(d["imp"] for d in data)

    print(f"\nИтого: потрачено {fmt(total_spend)} ₽, результатов {fmt(total_res, 0)}, "
          f"цена результата {fmt(cpa(total_spend, total_res))} ₽, показов {fmt(total_imp, 0)}")

    print("\nПол x возраст (по цене результата):")
    rows = []
    for d in sorted(data, key=lambda d: cpa(d["spend"], d["res"]) if d["res"] else 1e9):
        rows.append([
            f'{d["age"]} {d["sex"]}', fmt(d["spend"]), fmt(d["res"], 0), fmt(cpa(d["spend"], d["res"])),
            fmt(100 * d["spend"] / total_spend, 1), fmt(100 * d["imp"] / total_imp, 1),
        ])
    print_table(["Сегмент", "₽", "Результ.", "₽/результ.", "% бюджета", "% показов"], rows)

    for key, title in (("age", "Возраст"), ("sex", "Пол")):
        agg = defaultdict(lambda: [0.0, 0.0])
        for d in data:
            agg[d[key]][0] += d["spend"]
            agg[d[key]][1] += d["res"]
        print(f"\n{title}:")
        rows = [[k, fmt(s), fmt(r, 0), fmt(cpa(s, r)), fmt(100 * s / total_spend, 1)] for k, (s, r) in agg.items()]
        print_table([title, "₽", "Результ.", "₽/результ.", "% бюджета"], rows)


def report_geo(block, top):
    # В гео-выгрузке нет колонки расхода, а оплата идёт за показы. Для городов с результатами
    # расход = результаты x цена результата; остаток итога делим между остальными городами по показам.
    data = []
    for r in block["rows"]:
        res = num(r.get("Результат"))
        data.append(
            {
                "city": r["Регион"],
                "res": res,
                "imp": num(r.get("Показы")),
                "spend": res * num(r.get("Цена за результат, ₽")),
            }
        )
    total = block.get("total", {})
    total_res = sum(d["res"] for d in data)
    total_imp = sum(d["imp"] for d in data)
    total_spend = num(total.get("Результат")) * num(total.get("Цена за результат, ₽"))
    zero = [d for d in data if d["res"] == 0]
    zero_imp = sum(d["imp"] for d in zero)
    if total_spend and zero_imp:
        remainder = max(total_spend - sum(d["spend"] for d in data), 0.0)
        for d in zero:
            d["spend"] = remainder * d["imp"] / zero_imp
    else:
        total_spend = sum(d["spend"] for d in data)

    print(f"\nГородов: {len(data)}, расход ≈ {fmt(total_spend)} ₽, результатов {fmt(total_res, 0)}, "
          f"цена результата ≈ {fmt(cpa(total_spend, total_res))} ₽")
    zero_spend = sum(d["spend"] for d in zero)
    print(f"Без результатов: {len(zero)} городов, {fmt(100 * zero_imp / total_imp, 1)}% показов, "
          f"≈ {fmt(zero_spend)} ₽ ({fmt(100 * zero_spend / total_spend, 1)}% расхода)")

    rate = total_res / total_imp
    expected_zero = sum(math.exp(-d["imp"] * rate) for d in data)
    print(f"Если бы конверсия везде была одинаковой, городов без результатов было бы ≈ {fmt(expected_zero, 1)} "
          f"(факт: {len(zero)}). Близкие числа = нули по городам объясняются случайностью.")

    print("\nКонверсия по размеру города (результатов на 1000 показов):")
    rows = []
    for lo, hi in ((0, 20), (20, 50), (50, 100), (100, 200), (200, None)):
        sel = [d for d in data if d["imp"] >= lo and (hi is None or d["imp"] < hi)]
        imp, res = sum(d["imp"] for d in sel), sum(d["res"] for d in sel)
        label = f"{lo}+" if hi is None else f"{lo}–{hi - 1}"
        rows.append([label, len(sel), fmt(imp, 0), fmt(res, 0), fmt(1000 * res / imp, 1) if imp else "—"])
    print_table(["Показов в городе", "Городов", "Показы", "Результ.", "На 1000 показов"], rows)

    print(f"\nТоп-{top} по расходу (меньше ~20 результатов на город — это шум, а не сигнал):")
    rows = []
    for d in sorted(data, key=lambda d: -d["spend"])[:top]:
        rows.append([d["city"], fmt(d["spend"]), fmt(d["res"], 0), fmt(cpa(d["spend"], d["res"])), fmt(d["imp"], 0)])
    print_table(["Город", "₽", "Результ.", "₽/результ.", "Показы"], rows)


def parse_period(value):
    start, end = value.split(":")
    return date.fromisoformat(start), date.fromisoformat(end)


def report_log(path, baseline, test):
    with open(path, newline="", encoding="utf-8") as f:
        log = [r for r in csv.DictReader(f) if r.get("date")]
    for r in log:
        r["_date"] = date.fromisoformat(r["date"])
    log.sort(key=lambda r: r["_date"])

    print("\nПо дням (пустые ячейки = нет данных):")
    rows = []
    for r in log:
        spend, starts = num(r["ad_spend_rub"]), num(r["ad_listen_starts"])
        listeners, adds = num(r["studio_listeners"]), num(r["studio_adds"])
        rows.append([
            r["date"],
            r["ad_spend_rub"] or "—",
            r["studio_adds"] or "—",
            fmt(cpa(spend, starts)) if spend and starts else "—",
            fmt(cpa(spend, adds)) if spend and adds else "—",
            fmt(100 * adds / listeners, 0) if listeners and r["studio_adds"] else "—",
            r.get("reco_share_pct") or "—",
        ])
    print_table(["Дата", "₽ реклама", "Добавл.", "₽/старт", "₽/добавл.*", "Добавл./слуш., %", "Рекоменд., %"], rows)
    print("* расход делится на ВСЕ добавления, включая органику, поэтому это нижняя оценка цены.")

    if not (baseline and test):
        return

    def window(period):
        days = [r for r in log if period[0] <= r["_date"] <= period[1]]
        complete = [r for r in days if r["ad_spend_rub"] and r["studio_adds"]]
        if not complete:
            return None
        n = len(complete)
        return {
            "days": n,
            "spend": sum(num(r["ad_spend_rub"]) for r in complete) / n,
            "adds": sum(num(r["studio_adds"]) for r in complete) / n,
        }

    b, t = window(baseline), window(test)
    if not b or not t:
        print("\nНе хватает дней с заполненными расходом и добавлениями в одном из периодов.")
        return
    print(f"\nБаза: {b['days']} дн., в среднем {fmt(b['spend'])} ₽ и {fmt(b['adds'], 1)} добавл. в день")
    print(f"Тест: {t['days']} дн., в среднем {fmt(t['spend'])} ₽ и {fmt(t['adds'], 1)} добавл. в день")
    d_spend, d_adds = t["spend"] - b["spend"], t["adds"] - b["adds"]
    if d_adds <= 0:
        print("Добавлений не прибавилось: дополнительный бюджет не дал результата.")
        return
    inc = d_spend / d_adds
    print(f"Инкрементальная цена добавления: {fmt(inc)} ₽ (+{fmt(d_spend)} ₽/день -> +{fmt(d_adds, 1)} добавл./день)")
    if inc <= SCALE_MAX_CPA_ADD:
        verdict = "масштабировать: +30–50% к дневному бюджету и снова замерить через 5–7 дней"
    elif inc <= HOLD_MAX_CPA_ADD:
        verdict = "держать бюджет, работать над креативами и сегментами"
    else:
        verdict = "дорого: срезать бюджет и искать причину (усталость креатива, выгорание аудитории)"
    print(f"Вывод по правилам плана: {verdict}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("path")
    parser.add_argument("--top", type=int, default=20, help="сколько городов показать в гео-отчёте")
    parser.add_argument("--baseline", type=parse_period, help="базовый период YYYY-MM-DD:YYYY-MM-DD")
    parser.add_argument("--test", type=parse_period, help="тестовый период YYYY-MM-DD:YYYY-MM-DD")
    args = parser.parse_args()

    if args.path.lower().endswith(".csv"):
        report_log(args.path, args.baseline, args.test)
        return

    blocks = split_blocks(read_xlsx_rows(args.path))
    if not blocks:
        sys.exit("Не нашёл таблицу: ожидается выгрузка VK Рекламы с колонками «Результат» и «Показы».")
    for block in blocks:
        print(f"\n=== Группа {block['id']}: {block['name']} ===")
        if "Возраст" in block["header"]:
            report_demography(block)
        elif "Регион" in block["header"]:
            report_geo(block, args.top)
        else:
            sys.exit("Неизвестный тип выгрузки: нет колонки «Возраст» или «Регион».")


if __name__ == "__main__":
    main()
