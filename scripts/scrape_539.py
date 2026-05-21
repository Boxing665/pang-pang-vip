#!/usr/bin/env python3
"""
抓取 pilio.idv.tw 今彩539開獎記錄，輸出為 data/lotto539.json
由 GitHub Actions 每天 21:15 台灣時間自動執行
"""
import json
import os
import re
import time
from datetime import datetime, timezone, timedelta
from pathlib import Path

import requests
from bs4 import BeautifulSoup

BASE_URL = 'https://www.pilio.idv.tw/lto539/list.asp'
HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
    'Accept': 'text/html,application/xhtml+xml',
}

def fetch_page(page: int) -> list[dict]:
    """抓取一頁的 539 開獎記錄"""
    url = f'{BASE_URL}?indexpage={page}'
    try:
        resp = requests.get(url, headers=HEADERS, timeout=20)
        resp.raise_for_status()
    except Exception as e:
        print(f'  ⚠️  頁面 {page} 抓取失敗: {e}')
        return []

    soup = BeautifulSoup(resp.text, 'html.parser')
    records = []

    dates  = soup.select('td.date-cell')
    nums   = soup.select('td.number-cell')

    for d, n in zip(dates, nums):
        # 取 MM/DD 部分
        date_text = d.get_text(separator=' ').strip()
        date_match = re.search(r'\d{2}/\d{2}', date_text)
        if not date_match:
            continue
        date_str = date_match.group(0)

        # 解析號碼
        num_text = n.get_text(separator=',').replace('\xa0', ' ').strip()
        numbers = [int(x) for x in re.findall(r'\d+', num_text) if 1 <= int(x) <= 39]
        if len(numbers) != 5:
            continue

        records.append({'date': date_str, 'numbers': numbers})

    print(f'  ✅ 頁面 {page}: {len(records)} 筆')
    return records


def main():
    all_records = []
    seen = set()

    for page in range(1, 6):
        records = fetch_page(page)
        for r in records:
            key = r['date'] + str(r['numbers'])
            if key not in seen:
                seen.add(key)
                all_records.append(r)
        time.sleep(1.0)  # 禮貌性延遲

    # 台灣時間
    tw_now = datetime.now(timezone(timedelta(hours=8)))
    output = {
        'updated': tw_now.strftime('%Y-%m-%d %H:%M TW'),
        'count': len(all_records),
        'records': all_records,
    }

    out_path = Path(__file__).parent.parent / 'data' / 'lotto539.json'
    out_path.parent.mkdir(exist_ok=True)
    out_path.write_text(json.dumps(output, ensure_ascii=False, indent=2), encoding='utf-8')
    print(f'📄 已儲存 {len(all_records)} 筆記錄 → {out_path}')


if __name__ == '__main__':
    main()
