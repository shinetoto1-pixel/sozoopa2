import json
import math
from pathlib import Path

import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch

plt.rcParams["font.family"] = "Malgun Gothic"
plt.rcParams["axes.unicode_minus"] = False

# --- palette (dataviz skill reference palette, light mode) ---
SURFACE_PAGE = "#f9f9f7"
SURFACE_TILE = "#fcfcfb"
INK_PRIMARY = "#0b0b0b"
INK_SECONDARY = "#52514e"
INK_MUTED = "#898781"
BORDER = (0.043, 0.043, 0.043, 0.10)  # rgba(11,11,11,0.10)
UP_COLOR = "#e34948"    # diverging red (상승)
DOWN_COLOR = "#2a78d6"  # diverging blue (하락)
FLAT_COLOR = "#898781"

SECTION_ORDER = ["증시", "환율", "금리", "원자재"]
SECTION_ACCENTS = {
    "증시": "#2a78d6",   # blue
    "환율": "#1baf7a",   # aqua
    "금리": "#4a3aa7",   # violet
    "원자재": "#eda100",  # yellow/amber
}
# 원래(첫 버전) 폭 배열 그대로 유지 — 대분류는 세로로만 쌓는다
SECTION_COLS = {"증시": 4, "환율": 3, "금리": 3, "원자재": 4}

# --- layout constants, in inches ---
FIG_W = 9.6
MARGIN_X = 0.32
TOP_TITLE_H = 0.5
SECTION_HEADER_H = 0.42
TILE_H = 0.92
ROW_GAP = 0.1
TILE_GAP_X = 0.1
SECTION_GAP = 0.26
BOTTOM_MARGIN = 0.18


def _fmt_pct(pct):
    sign = "+" if pct > 0 else ("" if pct < 0 else "")
    return f"{sign}{pct:.2f}%"


def draw_tile(ax, x, y, w, h, item):
    """Draw one stat tile: label, value, delta. (x, y) = bottom-left, in inches."""
    box = FancyBboxPatch(
        (x, y), w, h,
        boxstyle="round,pad=0,rounding_size=0.05",
        linewidth=1.0,
        edgecolor=BORDER,
        facecolor=SURFACE_TILE,
    )
    ax.add_patch(box)

    pct = item["pct"]
    if pct > 0:
        color, arrow = UP_COLOR, "▲"
    elif pct < 0:
        color, arrow = DOWN_COLOR, "▼"
    else:
        color, arrow = FLAT_COLOR, "-"

    pad_x = w * 0.07
    ax.text(x + pad_x, y + h * 0.78, item["name"], fontsize=10.5,
            color=INK_SECONDARY, ha="left", va="center", fontweight="normal")
    unit = item.get("unit", "")
    value_str = f'{item["value"]}{unit}'
    ax.text(x + pad_x, y + h * 0.46, value_str, fontsize=14.5,
            color=INK_PRIMARY, ha="left", va="center", fontweight="bold")
    delta_str = f'{arrow} {_fmt_pct(pct)}'
    ax.text(x + pad_x, y + h * 0.15, delta_str, fontsize=10,
            color=color, ha="left", va="center", fontweight="bold")
    if item.get("date"):
        ax.text(x + w - pad_x, y + h * 0.87, item["date"], fontsize=8,
                color=INK_MUTED, ha="right", va="center")


def section_height(n_items, ncols):
    nrows = math.ceil(n_items / ncols)
    return SECTION_HEADER_H + nrows * TILE_H + (nrows - 1) * ROW_GAP


def draw_section(ax, x0, y_top, w, title, items, ncols):
    """Draw one section panel with its top-left origin at (x0, y_top); returns height used."""
    accent = SECTION_ACCENTS[title]
    header_y = y_top - SECTION_HEADER_H
    # 작은 액센트 바를 헤더 맨 위쪽에 얇게, 글씨와 겹치지 않게 충분한 간격을 두고 배치
    ax.add_patch(plt.Rectangle((x0, header_y + SECTION_HEADER_H - 0.08), 0.34, 0.07,
                                facecolor=accent, edgecolor="none"))
    ax.text(x0, header_y + SECTION_HEADER_H * 0.32, title, fontsize=15.5,
            color=INK_PRIMARY, ha="left", va="center", fontweight="bold")

    nrows = math.ceil(len(items) / ncols)
    tile_w = (w - TILE_GAP_X * (ncols - 1)) / ncols
    grid_top = header_y

    for i, item in enumerate(items):
        r, c = divmod(i, ncols)
        tx = x0 + c * (tile_w + TILE_GAP_X)
        ty = grid_top - (r + 1) * TILE_H - r * ROW_GAP
        draw_tile(ax, tx, ty, tile_w, TILE_H, item)

    return SECTION_HEADER_H + nrows * TILE_H + (nrows - 1) * ROW_GAP


def build_market_summary(data, out_path="charts/market_summary.png"):
    panel_w = FIG_W - 2 * MARGIN_X  # 대분류 패널은 전체 폭을 그대로 사용

    total_h = TOP_TITLE_H + BOTTOM_MARGIN
    for title in SECTION_ORDER:
        total_h += section_height(len(data[title]), SECTION_COLS[title])
    total_h += SECTION_GAP * (len(SECTION_ORDER) - 1)

    fig = plt.figure(figsize=(FIG_W, total_h), facecolor=SURFACE_PAGE)
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(0, FIG_W)
    ax.set_ylim(0, total_h)
    ax.set_aspect("equal")
    ax.axis("off")

    ax.text(MARGIN_X, total_h - TOP_TITLE_H * 0.55, f'{data["date"]} 시장 지표', fontsize=19,
            color=INK_PRIMARY, fontweight="bold", ha="left", va="center")
    ax.text(FIG_W - MARGIN_X, total_h - TOP_TITLE_H * 0.55, "다음뉴스 금융지표", fontsize=9.5,
            color=INK_MUTED, ha="right", va="center")

    cursor_y = total_h - TOP_TITLE_H
    for title in SECTION_ORDER:
        used = draw_section(ax, MARGIN_X, cursor_y, panel_w, title, data[title], SECTION_COLS[title])
        cursor_y -= used + SECTION_GAP

    Path(out_path).parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_path, dpi=160, facecolor=SURFACE_PAGE)
    plt.close(fig)
    print("saved:", out_path)


if __name__ == "__main__":
    with open(Path(__file__).parent / "market_data.json", encoding="utf-8") as f:
        data = json.load(f)
    build_market_summary(data)
