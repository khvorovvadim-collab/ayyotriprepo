#!/usr/bin/env python3
"""Combine the coordinated G KIDS looks into two large style capsules."""

from __future__ import annotations

import csv
import sys
from pathlib import Path

import pymupdf
from PIL import Image, ImageDraw

from build_capsules import Item, fit_image, get_font, parse_items, render_item_images
from build_outfits import LOOKS, repair_grouped_outerwear


PDF_PATH = Path(
    sys.argv[1]
    if len(sys.argv) > 1
    else "/home/ubuntu/.cursor/projects/workspace/uploads/___________________400c.pdf"
)
OUTPUT_DIR = Path(sys.argv[2] if len(sys.argv) > 2 else "/workspace/output")


CAPSULES = {
    "Bright Picnic": {
        "ru": "ЯРКИЙ ПИКНИК",
        "principle": (
            "Тёплые жёлтые, розовые и зелёные оттенки, фруктовые и наивные принты, "
            "выразительные цветовые сочетания."
        ),
        "accent": "#EC7995",
        "bg": "#FFF7F2",
        "sources": {
            "Picnic Club": None,
            "Candy Pop": None,
            "Sunny Day": None,
            "Sporty Fun": (0, 2),
        },
    },
    "Pastel Club": {
        "ru": "ПАСТЕЛЬНЫЙ КЛУБ",
        "principle": (
            "Мятная, голубая и сиреневая гамма, светлый деним, спокойная база "
            "и расслабленные спортивные формы."
        ),
        "accent": "#769DB5",
        "bg": "#F5F9FA",
        "sources": {
            "Mint & Lavender": None,
            "Pastel Basics": None,
            "Denim Club": None,
            "Sporty Fun": (2, None),
        },
    },
}


def get_capsule_pairs(capsule: dict) -> list[tuple[tuple[int, int, int], tuple[int, int, int]]]:
    result = []
    for source, bounds in capsule["sources"].items():
        pairs = LOOKS[source]
        if bounds is not None:
            start, stop = bounds
            pairs = pairs[start:stop]
        result.extend(pairs)
    return result


def paste_centered(
    board: Image.Image,
    image: Image.Image,
    box: tuple[int, int, int, int],
) -> None:
    left, top, right, bottom = box
    fitted = fit_image(image, right - left, bottom - top)
    x = left + (right - left - fitted.width) // 2
    y = top + (bottom - top - fitted.height) // 2
    board.paste(fitted, (x, y))


def make_board(
    capsule_name: str,
    capsule: dict,
    looks: list[tuple[Item, Item]],
) -> Image.Image:
    width, height = 2400, 1600
    board = Image.new("RGB", (width, height), capsule["bg"])
    draw = ImageDraw.Draw(board)
    draw.rectangle((0, 0, 30, height), fill=capsule["accent"])
    draw.text((86, 55), capsule["ru"], font=get_font(58, True), fill="#171717")
    draw.text((88, 128), capsule_name.upper(), font=get_font(25, True), fill=capsule["accent"])
    draw.text(
        (88, 190),
        f"Принцип: {capsule['principle']}",
        font=get_font(27),
        fill="#3F3F3F",
    )
    draw.line((88, 255, 2312, 255), fill=capsule["accent"], width=3)

    cols, rows = 5, 4
    gap = 20
    left, top = 88, 285
    card_w = (2224 - gap * (cols - 1)) // cols
    card_h = (1260 - gap * (rows - 1)) // rows
    for index, (top_item, bottom_item) in enumerate(looks):
        row, col = divmod(index, cols)
        x = left + col * (card_w + gap)
        y = top + row * (card_h + gap)
        draw.rounded_rectangle(
            (x, y, x + card_w, y + card_h),
            radius=16,
            fill="#FFFFFF",
            outline=capsule["accent"],
            width=2,
        )
        draw.text(
            (x + 15, y + 12),
            f"КОМПЛЕКТ {index + 1}",
            font=get_font(15, True),
            fill=capsule["accent"],
        )
        if top_item.image:
            paste_centered(board, top_item.image, (x + 12, y + 38, x + 180, y + 150))
        if bottom_item.image:
            paste_centered(board, bottom_item.image, (x + 12, y + 160, x + 180, y + card_h - 12))

        draw.line((x + 192, y + 42, x + 192, y + card_h - 14), fill="#E4E4E4", width=2)
        draw.text((x + 208, y + 48), "ВЕРХ", font=get_font(13, True), fill=capsule["accent"])
        draw.text((x + 208, y + 72), top_item.sku, font=get_font(18, True), fill="#222222")
        draw.text((x + 208, y + 98), top_item.color, font=get_font(15), fill="#5B5B5B")
        draw.line((x + 208, y + 146, x + card_w - 15, y + 146), fill="#E6E6E6", width=1)
        draw.text((x + 208, y + 163), "НИЗ", font=get_font(13, True), fill=capsule["accent"])
        draw.text((x + 208, y + 187), bottom_item.sku, font=get_font(18, True), fill="#222222")
        draw.text((x + 208, y + 213), bottom_item.color, font=get_font(15), fill="#5B5B5B")
    return board


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    image_dir = OUTPUT_DIR / "two_capsules"
    image_dir.mkdir(parents=True, exist_ok=True)

    doc = pymupdf.open(PDF_PATH)
    items = parse_items(doc)
    render_item_images(doc, items)
    repair_grouped_outerwear(doc, items)
    by_position = {(item.page, item.row, item.col): item for item in items}

    boards: list[Image.Image] = []
    csv_rows: list[list[str | int]] = []
    for board_number, (capsule_name, capsule) in enumerate(CAPSULES.items(), 1):
        pairs = get_capsule_pairs(capsule)
        looks = [(by_position[top], by_position[bottom]) for top, bottom in pairs]
        board = make_board(capsule_name, capsule, looks)
        board.save(image_dir / f"{board_number:02d}_{capsule_name.lower().replace(' ', '_')}.png")
        boards.append(board)
        for look_number, (top_item, bottom_item) in enumerate(looks, 1):
            csv_rows.append(
                [
                    capsule["ru"],
                    look_number,
                    top_item.sku,
                    top_item.color,
                    bottom_item.sku,
                    bottom_item.color,
                ]
            )

    with (OUTPUT_DIR / "two_capsule_pairs.csv").open("w", newline="", encoding="utf-8-sig") as handle:
        writer = csv.writer(handle)
        writer.writerow(["Капсула", "Комплект", "Артикул верха", "Цвет верха", "Артикул низа", "Цвет низа"])
        writer.writerows(csv_rows)

    boards[0].save(
        OUTPUT_DIR / "G_KIDS_two_capsules.pdf",
        save_all=True,
        append_images=boards[1:],
        resolution=150,
    )
    print(f"Created {len(csv_rows)} looks in {len(boards)} capsules")


if __name__ == "__main__":
    main()
