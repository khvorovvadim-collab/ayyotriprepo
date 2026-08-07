#!/usr/bin/env python3
"""Create coordinated top-and-bottom looks from the G KIDS assortment."""

from __future__ import annotations

import csv
import io
import sys
from pathlib import Path

import pymupdf
from PIL import Image, ImageDraw

from build_capsules import (
    Item,
    RENDER_SCALE,
    fit_image,
    get_font,
    parse_items,
    render_item_images,
)


PDF_PATH = Path(
    sys.argv[1]
    if len(sys.argv) > 1
    else "/home/ubuntu/.cursor/projects/workspace/uploads/___________________400c.pdf"
)
OUTPUT_DIR = Path(sys.argv[2] if len(sys.argv) > 2 else "/workspace/output")


LOOK_INFO = {
    "Picnic Club": {
        "ru": "ПИКНИК-КЛУБ",
        "principle": "Лёгкий принтованный верх + светлый деним или мягкий пастельный низ.",
        "accent": "#EFA6B8",
        "bg": "#FFF8F4",
    },
    "Candy Pop": {
        "ru": "CANDY POP",
        "principle": "Розовые и сиреневые верхи соединены с низами той же насыщенности.",
        "accent": "#EE6E9F",
        "bg": "#FFF4F8",
    },
    "Sunny Day": {
        "ru": "СОЛНЕЧНЫЙ ДЕНЬ",
        "principle": "Тёплые жёлтые, оранжевые и салатовые оттенки собраны в яркие комплекты.",
        "accent": "#E9B72E",
        "bg": "#FFFBEF",
    },
    "Mint & Lavender": {
        "ru": "МЯТА И ЛАВАНДА",
        "principle": "Холодные пастельные верхи сочетаются с голубыми, мятными и лиловыми низами.",
        "accent": "#8BBFB5",
        "bg": "#F4FBFA",
    },
    "Pastel Basics": {
        "ru": "ПАСТЕЛЬНАЯ БАЗА",
        "principle": "Спокойные однотонные верхи и низы образуют универсальные комплекты.",
        "accent": "#B6A9A2",
        "bg": "#FAF8F6",
    },
    "Denim Club": {
        "ru": "ДЕНИМ-КЛУБ",
        "principle": "Джинсовый верх и низ объединены по оттенку и степени высветления денима.",
        "accent": "#779EC0",
        "bg": "#F3F8FC",
    },
    "Sporty Fun": {
        "ru": "SPORTY FUN",
        "principle": "Худи и свитшоты дополнены комфортными шортами и свободными брюками.",
        "accent": "#9B8ACB",
        "bg": "#F7F5FC",
    },
}


# Every available bottom is used exactly once. Keys are (page, row, column).
LOOKS = {
    "Picnic Club": [
        ((1, 1, 1), (2, 1, 1)),
        ((1, 1, 2), (2, 1, 2)),
        ((1, 1, 4), (2, 1, 5)),
        ((1, 2, 2), (2, 2, 3)),
        ((1, 3, 1), (2, 1, 6)),
    ],
    "Candy Pop": [
        ((1, 2, 3), (2, 2, 1)),
        ((1, 2, 4), (2, 2, 5)),
        ((1, 2, 5), (2, 2, 6)),
        ((1, 2, 8), (2, 2, 2)),
        ((1, 5, 4), (2, 2, 7)),
        ((1, 5, 5), (2, 2, 4)),
    ],
    "Sunny Day": [
        ((1, 1, 8), (2, 3, 4)),
        ((1, 2, 1), (2, 3, 5)),
        ((1, 3, 7), (2, 3, 3)),
        ((1, 4, 5), (2, 3, 1)),
        ((1, 4, 7), (2, 3, 7)),
        ((1, 5, 9), (2, 3, 2)),
    ],
    "Mint & Lavender": [
        ((1, 1, 5), (2, 5, 1)),
        ((1, 2, 6), (2, 1, 7)),
        ((1, 2, 9), (2, 5, 2)),
        ((1, 3, 3), (2, 1, 3)),
        ((1, 3, 6), (2, 4, 6)),
    ],
    "Pastel Basics": [
        ((1, 1, 3), (2, 4, 1)),
        ((1, 2, 7), (2, 4, 2)),
        ((1, 3, 5), (2, 4, 8)),
        ((1, 4, 1), (2, 4, 3)),
        ((1, 5, 1), (2, 4, 4)),
    ],
    "Denim Club": [
        ((1, 7, 1), (2, 1, 9)),
        ((1, 7, 2), (2, 1, 4)),
        ((1, 7, 3), (2, 3, 8)),
        ((1, 7, 4), (2, 5, 3)),
        ((1, 7, 5), (2, 5, 4)),
    ],
    "Sporty Fun": [
        ((1, 6, 2), (2, 2, 8)),
        ((1, 6, 4), (2, 4, 5)),
        ((1, 6, 6), (2, 3, 6)),
        ((1, 6, 7), (2, 4, 7)),
        ((1, 6, 5), (2, 1, 8)),
    ],
}


def repair_grouped_outerwear(doc: pymupdf.Document, items: list[Item]) -> None:
    """Crop three source garments that share one embedded PDF image."""
    page = doc[0]
    pixmap = page.get_pixmap(
        matrix=pymupdf.Matrix(RENDER_SCALE, RENDER_SCALE),
        alpha=False,
    )
    page_image = Image.open(io.BytesIO(pixmap.tobytes("png"))).convert("RGB")
    affected = [item for item in items if item.page == 1 and item.row == 6 and item.col in {5, 6, 7}]
    for item in affected:
        center_x = (item.label_bbox[0] + item.label_bbox[2]) / 2
        box = (
            int((center_x - 27) * RENDER_SCALE),
            int(395 * RENDER_SCALE),
            int((center_x + 27) * RENDER_SCALE),
            int((item.label_bbox[1] - 2) * RENDER_SCALE),
        )
        item.image = page_image.crop(box)


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


def make_board(category: str, looks: list[tuple[Item, Item]]) -> Image.Image:
    info = LOOK_INFO[category]
    width, height = 1600, 1000
    board = Image.new("RGB", (width, height), info["bg"])
    draw = ImageDraw.Draw(board)
    draw.rectangle((0, 0, 24, height), fill=info["accent"])
    draw.text((72, 42), info["ru"], font=get_font(42, True), fill="#161616")
    draw.text((72, 96), category.upper(), font=get_font(20, True), fill=info["accent"])
    draw.text(
        (72, 140),
        f"Принцип: {info['principle']}",
        font=get_font(22),
        fill="#3F3F3F",
    )
    draw.line((72, 195, 1528, 195), fill=info["accent"], width=2)

    cols, rows = 3, 2
    gap = 24
    grid_left, grid_top = 72, 220
    card_w = (1456 - gap * (cols - 1)) // cols
    card_h = (720 - gap) // rows
    for index, (top_item, bottom_item) in enumerate(looks):
        row, col = divmod(index, cols)
        x = grid_left + col * (card_w + gap)
        y = grid_top + row * (card_h + gap)
        draw.rounded_rectangle(
            (x, y, x + card_w, y + card_h),
            radius=18,
            fill="#FFFFFF",
            outline=info["accent"],
            width=2,
        )
        draw.text(
            (x + 20, y + 14),
            f"КОМПЛЕКТ {index + 1}",
            font=get_font(16, True),
            fill=info["accent"],
        )
        if top_item.image:
            paste_centered(board, top_item.image, (x + 18, y + 45, x + 205, y + 170))
        if bottom_item.image:
            paste_centered(board, bottom_item.image, (x + 18, y + 182, x + 205, y + 326))

        draw.line((x + 220, y + 48, x + 220, y + card_h - 22), fill="#E4E4E4", width=2)
        draw.text((x + 240, y + 60), "ВЕРХ", font=get_font(14, True), fill=info["accent"])
        draw.text((x + 240, y + 86), top_item.sku, font=get_font(20, True), fill="#202020")
        draw.text((x + 240, y + 114), top_item.color, font=get_font(17), fill="#5A5A5A")
        draw.line((x + 240, y + 166, x + card_w - 22, y + 166), fill="#E4E4E4", width=1)
        draw.text((x + 240, y + 188), "НИЗ", font=get_font(14, True), fill=info["accent"])
        draw.text((x + 240, y + 214), bottom_item.sku, font=get_font(20, True), fill="#202020")
        draw.text((x + 240, y + 242), bottom_item.color, font=get_font(17), fill="#5A5A5A")
    return board


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    image_dir = OUTPUT_DIR / "outfit_sets"
    image_dir.mkdir(parents=True, exist_ok=True)

    doc = pymupdf.open(PDF_PATH)
    items = parse_items(doc)
    render_item_images(doc, items)
    repair_grouped_outerwear(doc, items)
    by_position = {(item.page, item.row, item.col): item for item in items}

    boards: list[Image.Image] = []
    csv_rows: list[list[str | int]] = []
    for board_number, (category, pairs) in enumerate(LOOKS.items(), 1):
        looks = [(by_position[top], by_position[bottom]) for top, bottom in pairs]
        board = make_board(category, looks)
        board.save(image_dir / f"{board_number:02d}_{category.lower().replace(' ', '_').replace('&', 'and')}.png")
        boards.append(board)
        for look_number, (top_item, bottom_item) in enumerate(looks, 1):
            csv_rows.append(
                [
                    category,
                    look_number,
                    top_item.sku,
                    top_item.color,
                    bottom_item.sku,
                    bottom_item.color,
                ]
            )

    with (OUTPUT_DIR / "outfit_pairs.csv").open("w", newline="", encoding="utf-8-sig") as handle:
        writer = csv.writer(handle)
        writer.writerow(["Капсула", "Комплект", "Артикул верха", "Цвет верха", "Артикул низа", "Цвет низа"])
        writer.writerows(csv_rows)

    boards[0].save(
        OUTPUT_DIR / "G_KIDS_outfit_sets.pdf",
        save_all=True,
        append_images=boards[1:],
        resolution=150,
    )
    print(f"Created {len(csv_rows)} coordinated looks on {len(boards)} boards")


if __name__ == "__main__":
    main()
