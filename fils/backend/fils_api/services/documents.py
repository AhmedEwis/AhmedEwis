"""Statement extraction → candidate transactions for preview/correction on device. Nothing is posted."""
from __future__ import annotations

import csv
import io
import re
from datetime import datetime

from pypdf import PdfReader

from .textguard import normalize_currency, normalize_digits, to_minor

DATE_PATTERNS = [
    (re.compile(r"\b(\d{1,2})[/-](\d{1,2})[/-](\d{4})\b"), "dmy"),
    (re.compile(r"\b(\d{4})-(\d{1,2})-(\d{1,2})\b"), "ymd"),
    (re.compile(r"\b(\d{1,2})[ -]([A-Za-z]{3})[ -](\d{2,4})\b"), "dMy"),
]
MONTHS = {m: i for i, m in enumerate(["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"], 1)}
AMOUNT = re.compile(r"(?<![\d.])(\d{1,3}(?:,\d{3})*|\d+)\.(\d{2,3})(?![\d.])")
MAX_ROWS = 5000


def parse_date(s: str) -> str | None:
    s = normalize_digits(s)
    for pat, kind in DATE_PATTERNS:
        m = pat.search(s)
        if not m:
            continue
        try:
            if kind == "dmy":
                d, mo, y = int(m[1]), int(m[2]), int(m[3])
            elif kind == "ymd":
                y, mo, d = int(m[1]), int(m[2]), int(m[3])
            else:
                d, mo, y = int(m[1]), MONTHS.get(m[2].lower(), 0), int(m[3])
                y = y + 2000 if y < 100 else y
            return datetime(y, mo, d).date().isoformat()
        except ValueError:
            continue
    return None


def _find_col(headers: list[str], *names: str) -> int | None:
    low = [h.strip().lower() for h in headers]
    for n in names:
        for i, h in enumerate(low):
            if n in h:
                return i
    return None


def extract_csv(data: bytes, default_currency: str = "KWD") -> list[dict]:
    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError:
        text = data.decode("cp1256")
    rows = list(csv.reader(io.StringIO(text)))
    if not rows:
        return []
    headers = rows[0]
    c_date = _find_col(headers, "date", "تاريخ")
    c_desc = _find_col(headers, "description", "details", "narrative", "merchant", "البيان", "الوصف", "التفاصيل")
    c_amt = _find_col(headers, "amount", "المبلغ")
    c_debit = _find_col(headers, "debit", "withdrawal", "مدين", "سحب")
    c_credit = _find_col(headers, "credit", "deposit", "دائن", "إيداع", "ايداع")
    c_cur = _find_col(headers, "currency", "العملة")
    out = []
    for r in rows[1 : MAX_ROWS + 1]:
        if not any(x.strip() for x in r):
            continue
        get = lambda i: r[i].strip() if i is not None and i < len(r) else ""  # noqa: E731
        currency = normalize_currency(get(c_cur)) or default_currency
        direction = None
        raw_amt = ""
        if c_debit is not None and get(c_debit):
            raw_amt, direction = get(c_debit), "debit"
        elif c_credit is not None and get(c_credit):
            raw_amt, direction = get(c_credit), "credit"
        elif c_amt is not None:
            raw_amt = get(c_amt)
            direction = "debit" if raw_amt.strip().startswith("-") or raw_amt.strip().startswith("(") else "credit"
        clean = re.sub(r"[()\-\s]", "", raw_amt)
        minor = to_minor(clean, currency) if clean else None
        out.append(
            {
                "occurred_on": parse_date(get(c_date)) if c_date is not None else None,
                "description": get(c_desc)[:200],
                "amount_minor": minor,
                "currency": currency,
                "direction": direction,
                "needs_review": minor is None or direction is None,
            }
        )
    return out


def extract_lines(text: str, default_currency: str = "KWD") -> list[dict]:
    out = []
    for line in normalize_digits(text).splitlines():
        line = line.strip()
        if len(line) < 8:
            continue
        date = parse_date(line)
        amounts = AMOUNT.findall(line)
        if not date or not amounts:
            continue
        # Statements usually print amount then running balance; the FIRST amount is the transaction.
        whole, frac = amounts[0]
        cur = default_currency
        for tok in ("KWD", "USD", "EUR", "SAR", "AED", "GBP", "BHD", "QAR", "EGP"):
            if tok in line.upper():
                cur = tok
                break
        minor = to_minor(f"{whole}.{frac}", cur)
        desc = AMOUNT.sub("", line)
        for pat, _ in DATE_PATTERNS:
            desc = pat.sub("", desc)
        direction = "credit" if re.search(r"\b(cr|credit|deposit|salary|راتب|إيداع|ايداع)\b", line, re.I) else "debit"
        out.append(
            {
                "occurred_on": date,
                "description": re.sub(r"\s+", " ", desc).strip()[:200],
                "amount_minor": minor,
                "currency": cur,
                "direction": direction,
                "needs_review": True,  # PDF/OCR layouts vary: always confirm on device
            }
        )
        if len(out) >= MAX_ROWS:
            break
    return out


def extract_pdf(data: bytes) -> list[dict]:
    reader = PdfReader(io.BytesIO(data))
    if reader.is_encrypted:
        raise ValueError("encrypted_pdf")
    text = "\n".join((p.extract_text() or "") for p in reader.pages[:50])
    return extract_lines(text)
