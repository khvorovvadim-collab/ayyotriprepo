#!/usr/bin/env python3
"""Build visual style capsules from the supplied G KIDS assortment PDF."""

from __future__ import annotations

import csv
import io
import math
import re
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path

import pymupdf
from PIL import Image, ImageDraw, ImageFont


PDF_PATH = Path(
    sys.argv[1]
    if len(sys.argv) > 1
    else "/home/ubuntu/.cursor/projects/workspace/uploads/___________________400c.pdf"
)
OUTPUT_DIR = Path(sys.argv[2] if len(sys.argv) > 2 else "/workspace/output")
FONT_REGULAR = "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf"
FONT_BOLD = "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf"
SKU_RE = re.compile(r"G[A-Z]{2}\d{6}")
RENDER_SCALE = 5


@dataclass
class Item:
    page: int
    row: int
    col: int
    sku: str
    color: str
    label_bbox: tuple[float, float, float, float]
    image_bboxes: list[tuple[float, float, float, float]]
    image: Image.Image | None = None
    category: str = ""


CATEGORY_INFO = {
    "Picnic Club": {
        "ru": "ПИКНИК-КЛУБ",
        "principle": "Мелкие цветочные, фруктовые и наивные принты, рюши и светлая летняя база.",
        "accent": "#EFA6B8",
        "bg": "#FFF8F4",
    },
    "Candy Pop": {
        "ru": "CANDY POP",
        "principle": "Розово-малиновая гамма, сердечки, персонажи и активная графика.",
        "accent": "#EE6E9F",
        "bg": "#FFF4F8",
    },
    "Sunny Day": {
        "ru": "СОЛНЕЧНЫЙ ДЕНЬ",
        "principle": "Жёлтые, оранжевые и салатовые оттенки с тёплыми летними принтами.",
        "accent": "#E9B72E",
        "bg": "#FFFBEF",
    },
    "Mint & Lavender": {
        "ru": "МЯТА И ЛАВАНДА",
        "principle": "Холодные пастели: мятный, голубой и сиреневый; спокойная мягкая графика.",
        "accent": "#8BBFB5",
        "bg": "#F4FBFA",
    },
    "Pastel Basics": {
        "ru": "ПАСТЕЛЬНАЯ БАЗА",
        "principle": "Однотонные и почти нейтральные модели, которые связывают яркие вещи капсул.",
        "accent": "#B6A9A2",
        "bg": "#FAF8F6",
    },
    "Denim Club": {
        "ru": "ДЕНИМ-КЛУБ",
        "principle": "Светлый деним, голубые оттенки и практичные формы для городского casual.",
        "accent": "#779EC0",
        "bg": "#F3F8FC",
    },
    "Sporty Fun": {
        "ru": "SPORTY FUN",
        "principle": "Шорты, джоггеры и худи: свободные силуэты, комфорт и динамичная графика.",
        "accent": "#9B8ACB",
        "bg": "#F7F5FC",
    },
    "Romantic Garden": {
        "ru": "РОМАНТИЧЕСКИЙ САД",
        "principle": "Платья с воздушным объёмом, сборками, оборками и нежными принтами.",
        "accent": "#D8939F",
        "bg": "#FFF7F6",
    },
}


def get_font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(FONT_BOLD if bold else FONT_REGULAR, size)


def extract_color(words: list[tuple], code_word: tuple) -> str:
    candidates = [
        word
        for word in words
        if code_word[3] - 1 <= word[1] <= code_word[3] + 9
        and abs((word[0] + word[2]) / 2 - (code_word[0] + code_word[2]) / 2) < 30
        and word[4] != code_word[4]
    ]
    return min(candidates, key=lambda word: abs(word[1] - code_word[3]))[4] if candidates else ""


def cluster_rows(items: list[Item], tolerance: float = 15) -> None:
    groups: list[list[Item]] = []
    for item in sorted(items, key=lambda current: current.label_bbox[1]):
        if not groups or abs(item.label_bbox[1] - groups[-1][0].label_bbox[1]) > tolerance:
            groups.append([item])
        else:
            groups[-1].append(item)
    for row_number, group in enumerate(groups, 1):
        for col_number, item in enumerate(sorted(group, key=lambda current: current.label_bbox[0]), 1):
            item.row = row_number
            item.col = col_number


def parse_items(doc: pymupdf.Document) -> list[Item]:
    all_items: list[Item] = []
    for page_number, page in enumerate(doc, 1):
        words = page.get_text("words")
        page_items: list[Item] = []
        for word in words:
            if SKU_RE.fullmatch(word[4]):
                page_items.append(
                    Item(
                        page=page_number,
                        row=0,
                        col=0,
                        sku=word[4],
                        color=extract_color(words, word),
                        label_bbox=tuple(word[:4]),
                        image_bboxes=[],
                    )
                )

        for info in page.get_image_info(xrefs=True):
            bbox = tuple(info["bbox"])
            image_center = (bbox[0] + bbox[2]) / 2
            candidates: list[tuple[float, Item]] = []
            for item in page_items:
                label_center = (item.label_bbox[0] + item.label_bbox[2]) / 2
                vertical_gap = item.label_bbox[1] - bbox[3]
                if -5 <= vertical_gap <= 30:
                    score = abs(label_center - image_center) + max(vertical_gap, 0) * 0.3
                    candidates.append((score, item))
            if candidates:
                min(candidates, key=lambda candidate: candidate[0])[1].image_bboxes.append(bbox)

        cluster_rows(page_items)
        all_items.extend(page_items)
    return all_items


def assign_category(item: Item) -> str:
    # Product family is read from the source sheet's stable row structure.
    if item.page == 1 and item.row == 7:
        return "Denim Club"
    if item.page == 2:
        denim_positions = {
            (1, 1), (1, 2), (1, 3), (1, 4), (1, 8), (1, 9),
            (3, 8), (5, 3), (5, 4), (7, 1), (7, 2), (7, 3),
        }
        if (item.row, item.col) in denim_positions:
            return "Denim Club"
        if item.row >= 5 and (item.row > 5 or item.col >= 5):
            return "Romantic Garden"
        return "Sporty Fun"

    # Shirts and sweatshirts in row 6.
    if item.row == 6:
        if item.col in {2, 4, 6, 7}:
            return "Sporty Fun"
        if item.col == 5:
            return "Mint & Lavender"
        if item.col == 3:
            return "Candy Pop"
        return "Pastel Basics"

    picnic_positions = {
        (1, 1), (1, 2), (1, 4), (1, 6),
        (2, 2), (3, 1), (3, 2), (5, 8),
    }
    candy_positions = {
        (2, 3), (2, 4), (2, 5), (2, 8),
        (5, 2), (5, 3), (5, 4), (5, 5),
    }
    cool_positions = {
        (1, 5), (2, 6), (2, 9), (3, 3), (3, 4), (3, 6),
    }
    basic_positions = {
        (1, 3), (2, 7), (3, 5), (4, 1), (4, 2),
        (5, 1), (5, 6), (5, 7),
    }
    position = (item.row, item.col)
    if position in picnic_positions:
        return "Picnic Club"
    if position in candy_positions:
        return "Candy Pop"
    if position in cool_positions:
        return "Mint & Lavender"
    if position in basic_positions:
        return "Pastel Basics"
    return "Sunny Day"


def render_item_images(doc: pymupdf.Document, items: list[Item]) -> None:
    page_images: dict[int, Image.Image] = {}
    for page_number in {item.page for item in items}:
        pixmap = doc[page_number - 1].get_pixmap(
            matrix=pymupdf.Matrix(RENDER_SCALE, RENDER_SCALE), alpha=False
        )
        page_images[page_number] = Image.open(io.BytesIO(pixmap.tobytes("png"))).convert("RGB")

    for item in items:
        if not item.image_bboxes:
            continue
        left = min(box[0] for box in item.image_bboxes)
        top = min(box[1] for box in item.image_bboxes)
        right = max(box[2] for box in item.image_bboxes)
        bottom = min(
            max(box[3] for box in item.image_bboxes),
            item.label_bbox[1] - 1.5,
        )
        pad = 3
        crop_box = (
            int((left - pad) * RENDER_SCALE),
            int((top - pad) * RENDER_SCALE),
            int((right + pad) * RENDER_SCALE),
            int(bottom * RENDER_SCALE),
        )
        item.image = page_images[item.page].crop(crop_box)


def fit_image(image: Image.Image, width: int, height: int) -> Image.Image:
    result = image.copy()
    result.thumbnail((width, height), Image.Resampling.LANCZOS)
    return result


def draw_wrapped(
    draw: ImageDraw.ImageDraw,
    text: str,
    xy: tuple[int, int],
    max_width: int,
    font: ImageFont.FreeTypeFont,
    fill: str,
    line_spacing: int = 5,
) -> None:
    words = text.split()
    lines: list[str] = []
    line = ""
    for word in words:
        candidate = f"{line} {word}".strip()
        if draw.textbbox((0, 0), candidate, font=font)[2] <= max_width:
            line = candidate
        else:
            if line:
                lines.append(line)
            line = word
    if line:
        lines.append(line)
    draw.multiline_text(xy, "\n".join(lines), font=font, fill=fill, spacing=line_spacing)


def make_board(category: str, items: list[Item], part: int, total_parts: int) -> Image.Image:
    info = CATEGORY_INFO[category]
    width, height = 1600, 1000
    board = Image.new("RGB", (width, height), info["bg"])
    draw = ImageDraw.Draw(board)
    draw.rectangle((0, 0, 24, height), fill=info["accent"])
    title = info["ru"] + (f" · {part}/{total_parts}" if total_parts > 1 else "")
    draw.text((72, 48), title, font=get_font(42, True), fill="#161616")
    draw.text((72, 105), category.upper(), font=get_font(20, True), fill=info["accent"])
    draw_wrapped(
        draw,
        f"Принцип: {info['principle']}",
        (72, 145),
        1420,
        get_font(22),
        "#3F3F3F",
    )
    draw.line((72, 210, 1528, 210), fill=info["accent"], width=2)

    count = len(items)
    cols = 5 if count > 12 else 4
    rows = max(1, math.ceil(count / cols))
    grid_top = 235
    grid_bottom = 960
    cell_w = (width - 144) // cols
    cell_h = (grid_bottom - grid_top) // rows
    for index, item in enumerate(items):
        row, col = divmod(index, cols)
        x = 72 + col * cell_w
        y = grid_top + row * cell_h
        if item.image:
            product = fit_image(item.image, cell_w - 40, cell_h - 72)
            px = x + (cell_w - product.width) // 2
            py = y + max(2, (cell_h - 68 - product.height) // 2)
            board.paste(product, (px, py))
        draw.text((x + 12, y + cell_h - 58), item.sku, font=get_font(18, True), fill="#1C1C1C")
        draw.text((x + 12, y + cell_h - 34), item.color, font=get_font(16), fill="#555555")
    return board


def save_inventory(items: list[Item], output_dir: Path) -> None:
    with (output_dir / "capsule_inventory.csv").open("w", newline="", encoding="utf-8-sig") as handle:
        writer = csv.writer(handle)
        writer.writerow(["Страница", "Ряд", "Позиция", "Артикул", "Цвет", "Капсула"])
        for item in sorted(items, key=lambda current: (current.category, current.page, current.row, current.col)):
            writer.writerow([item.page, item.row, item.col, item.sku, item.color, item.category])


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    doc = pymupdf.open(PDF_PATH)
    items = parse_items(doc)
    for item in items:
        item.category = assign_category(item)
    render_item_images(doc, items)
    save_inventory(items, OUTPUT_DIR)

    grouped: dict[str, list[Item]] = defaultdict(list)
    for item in items:
        grouped[item.category].append(item)

    boards: list[Image.Image] = []
    board_number = 1
    for category in CATEGORY_INFO:
        category_items = sorted(grouped[category], key=lambda item: (item.page, item.row, item.col))
        chunks = [category_items[index : index + 20] for index in range(0, len(category_items), 20)]
        for part, chunk in enumerate(chunks, 1):
            board = make_board(category, chunk, part, len(chunks))
            board.save(OUTPUT_DIR / f"{board_number:02d}_{category.lower().replace(' ', '_').replace('&', 'and')}.png")
            boards.append(board)
            board_number += 1

    pdf_boards = [board.convert("RGB") for board in boards]
    pdf_boards[0].save(
        OUTPUT_DIR / "G_KIDS_style_capsules.pdf",
        save_all=True,
        append_images=pdf_boards[1:],
        resolution=150,
    )
    print(f"Created {len(boards)} boards from {len(items)} products")
    for category in CATEGORY_INFO:
        print(f"{category}: {len(grouped[category])}")


if __name__ == "__main__":
    main()
