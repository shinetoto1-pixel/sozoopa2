import time
from make_chart import make_chart

# 2026-07-29: 다음금융 API 기반으로 전환 — 종목코드는 6자리 그대로(.KS/.KQ 구분 불필요)
candidates = [
    # (code, name) 예: ("000660", "SK하이닉스")
]

results = []
for code, name in candidates:
    try:
        path = make_chart(code, name, count=100, out_path=f"charts/A{code}_{name}.png")
        results.append((code, name, "OK", path))
    except Exception as e:
        results.append((code, name, "FAIL", str(e)))
    time.sleep(1)  # 연속 요청 사이 텀

for r in results:
    print(r)
