import sys
from pathlib import Path

import pandas as pd
import requests
import mplfinance as mpf

# 2026-07-29: 야후파이낸스(지연 문제) 대신 다음금융 API로 전환.
# 브라우저 없이 Python requests만으로 당일자까지 정확한 OHLC를 받아온다.
API_URL = "https://finance.daum.net/api/charts/A{code}/days?limit={limit}&adjusted=true"
HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
}

# --- palette (dataviz 스킬 참고 팔레트) ---
SURFACE = "#fcfcfb"
INK_PRIMARY = "#0b0b0b"
INK_MUTED = "#898781"
GRID = "#e1e0d9"
UP_COLOR = "#e34948"    # 상승(빨강, 한국 증시 관례)
DOWN_COLOR = "#2a78d6"  # 하락(파랑)

MAV_PERIODS = (5, 20, 60, 120)
MAV_COLORS = {
    5: "#008300",    # 초록
    20: "#eb6834",   # 주황
    60: "#4a3aa7",   # 보라
    120: "#eda100",  # 금색
}
VOLUME_COLOR = "#1baf7a"  # 거래량은 상승/하락 구분 없이 이 색 하나로 통일
DIVIDER_COLOR = "#3a3a38"  # 캔들 패널과 거래량 패널 사이 구분선(진하게)


def _fetch_candles(code, count):
    """count봉을 화면에 표시하되, MA120이 처음부터 유효하도록 여유(120봉)를 더 받아온다."""
    ref = f"https://finance.daum.net/quotes/A{code}"
    headers = {**HEADERS, "Referer": ref}
    limit = count + max(MAV_PERIODS) + 10
    r = requests.get(API_URL.format(code=code, limit=limit), headers=headers, timeout=15)
    r.raise_for_status()
    payload = r.json()
    rows = payload["data"]
    if len(rows) < count:
        raise RuntimeError(f"A{code}: 데이터 부족 ({len(rows)}행, 요청 {count}행) — 종목코드 확인 필요")

    df = pd.DataFrame(rows)
    df["Date"] = pd.to_datetime(df["date"])
    df = df.set_index("Date").sort_index()
    df = df.rename(columns={
        "openingPrice": "Open", "highPrice": "High", "lowPrice": "Low",
        "tradePrice": "Close", "candleAccTradeVolume": "Volume",
    })
    df = df[["Open", "High", "Low", "Close", "Volume"]]
    # 다음금융 API는 아직 개장 전인 당일자에 대해 거래량 0짜리 placeholder 행을 얹어서 준다
    # (open=high=low=close=전일종가, volume=0) — 실제 봉이 아니므로 제거한다.
    while len(df) and df["Volume"].iloc[-1] == 0:
        df = df.iloc[:-1]
    return df


def make_chart(code, name, count=100, out_path=None):
    """
    code: 6자리 종목코드 (예: "000660"). 다음금융 내부적으로 "A"+코드로 조회됨.
    name: 차트 제목에 쓸 이름 (예: "SK하이닉스")
    count: 화면에 표시할 봉 개수 (기본 100봉)
    """
    df_full = _fetch_candles(code, count)
    for p in MAV_PERIODS:
        df_full[f"MA{p}"] = df_full["Close"].rolling(p).mean()
    df = df_full.iloc[-count:].copy()

    mc = mpf.make_marketcolors(
        up=UP_COLOR, down=DOWN_COLOR,
        edge={"up": UP_COLOR, "down": DOWN_COLOR},
        wick={"up": UP_COLOR, "down": DOWN_COLOR},
        volume={"up": VOLUME_COLOR, "down": VOLUME_COLOR},  # 상승/하락 구분 없이 통일된 초록
    )
    style = mpf.make_mpf_style(
        base_mpf_style="nightclouds",
        marketcolors=mc,
        facecolor=SURFACE,
        figcolor=SURFACE,
        gridcolor=GRID,
        gridstyle="-",
        gridaxis="both",
        rc={
            "font.family": "Malgun Gothic",
            "axes.unicode_minus": False,
            "axes.edgecolor": GRID,
            "axes.labelcolor": INK_MUTED,
            "xtick.color": INK_MUTED,
            "ytick.color": INK_MUTED,
            "text.color": INK_PRIMARY,
        },
    )

    aps = [
        mpf.make_addplot(df[f"MA{p}"], color=MAV_COLORS[p], width=1.3)
        for p in MAV_PERIODS
    ]

    if out_path is None:
        out_path = f"charts/A{code}.png"
    Path(out_path).parent.mkdir(parents=True, exist_ok=True)

    title = f"{name} ({code})"

    fig, axes = mpf.plot(
        df, type="candle", style=style, volume=True,
        addplot=aps, panel_ratios=(3, 1), title=title,
        returnfig=True, figsize=(10, 6.2),
        datetime_format="%m.%d", show_nontrading=False,
    )

    legend_handles = [
        axes[0].plot([], [], color=MAV_COLORS[p], linewidth=1.8, label=f"{p}일선")[0]
        for p in MAV_PERIODS
    ]
    legend = axes[0].legend(handles=legend_handles, loc="upper left", fontsize=8,
                             frameon=True, labelcolor=INK_MUTED)
    legend.get_frame().set_facecolor(SURFACE)  # 시작가가 높은 종목은 캔들과 겹쳐 보이던 문제 방지
    legend.get_frame().set_edgecolor("none")
    legend.get_frame().set_alpha(1.0)  # 완전 불투명 — 0.92라 심지가 살짝 비쳐 보이던 문제 발견돼서 수정
    legend.set_zorder(10)  # 캔들/이평선보다 항상 위에 그려지도록 강제

    import matplotlib.pyplot as plt
    from matplotlib.ticker import FuncFormatter

    plain_fmt = FuncFormatter(lambda v, _: f"{v:,.0f}")
    volume_ax = axes[2]  # [가격, 가격보조, 거래량, 거래량보조] 순서
    for a in (axes[0], volume_ax):
        try:
            a.ticklabel_format(style="plain", axis="y", useOffset=False)
        except AttributeError:
            pass
        a.yaxis.set_major_formatter(plain_fmt)
        a.yaxis.offsetText.set_visible(False)
        a.yaxis.offsetText.set_text("")
        # y축을 오른쪽으로 — 오늘 가격/거래량을 오른쪽에서 바로 확인할 수 있게
        a.yaxis.tick_right()
        a.yaxis.set_label_position("right")
        a.set_ylabel("")  # "Price"/"Volume" 글자는 안 보이는 게 어차피 아는 정보라 제거

    for bar in volume_ax.patches:  # 거래량 막대 테두리 제거
        bar.set_edgecolor("none")
        bar.set_linewidth(0)

    # 캔들 패널 ↔ 거래량 패널 사이 구분선을 진하게
    axes[0].spines["bottom"].set_color(DIVIDER_COLOR)
    axes[0].spines["bottom"].set_linewidth(1.6)
    volume_ax.spines["top"].set_color(DIVIDER_COLOR)
    volume_ax.spines["top"].set_linewidth(1.6)

    # x축 맨 오른쪽(가장 최근 봉)에도 날짜가 찍히도록 강제 추가 (기존 x범위는 그대로 유지)
    xlim = volume_ax.get_xlim()
    last_idx = len(df) - 1
    xticks = sorted(set(list(volume_ax.get_xticks()) + [last_idx]))
    volume_ax.set_xticks(xticks)
    volume_ax.set_xlim(xlim)

    # 오늘 종가를 y축(오른쪽)에 별도 눈금+점선으로 표기 — "지금 얼마인지"가 바로 보이게.
    # 기존 자동눈금 중 종가와 너무 가까워 겹치는 것은 빼고, 축 범위(ylim)도 원래대로 고정한다.
    ylim = axes[0].get_ylim()
    last_close = float(df["Close"].iloc[-1])
    threshold = 0.04 * (ylim[1] - ylim[0])
    auto_yticks = [t for t in axes[0].get_yticks() if abs(t - last_close) > threshold]
    axes[0].axhline(last_close, color=INK_PRIMARY, linewidth=0.9, linestyle="--", alpha=0.6)
    axes[0].set_yticks(sorted(auto_yticks + [last_close]))
    axes[0].set_ylim(ylim)

    fig.savefig(out_path, dpi=150, facecolor=SURFACE)
    plt.close(fig)
    return out_path


if __name__ == "__main__":
    # 사용 예: python make_chart.py 000660 SK하이닉스 [봉개수]
    code = sys.argv[1] if len(sys.argv) > 1 else "000660"
    name = sys.argv[2] if len(sys.argv) > 2 else code
    count = int(sys.argv[3]) if len(sys.argv) > 3 else 100
    path = make_chart(code, name, count=count)
    print(f"saved: {path}")
