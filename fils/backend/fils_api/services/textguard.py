"""Text safety helpers shared by ingestion, samples and documents.

Message text is untrusted *data*. Nothing here interprets it as instructions.
"""
from __future__ import annotations

import re
from decimal import ROUND_HALF_UP, Decimal, InvalidOperation

CURRENCY_EXPONENT = {
    "KWD": 3, "BHD": 3, "OMR": 3, "JOD": 3, "IQD": 3, "TND": 3, "LYD": 3,
    "JPY": 0, "KRW": 0, "VND": 0, "CLP": 0, "ISK": 0, "UGX": 0,
}

CURRENCY_ALIASES = {
    "KD": "KWD", "K.D": "KWD", "K.D.": "KWD", "د.ك": "KWD", "دك": "KWD", "دينار": "KWD", "دينار كويتي": "KWD",
    "SR": "SAR", "ر.س": "SAR", "ريال": "SAR", "AED": "AED", "درهم": "AED", "$": "USD", "US$": "USD",
    "€": "EUR", "£": "GBP", "BD": "BHD", "QR": "QAR", "RO": "OMR", "ج.م": "EGP", "جنيه": "EGP", "LE": "EGP",
}

_ARABIC_DIGITS = str.maketrans("٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹٫٬", "01234567890123456789.,")

OTP_PATTERNS = [
    re.compile(r"\b(otp|one[\s-]?time\s*(pass(word|code)?|pin)|verification\s*code|security\s*code|activation\s*code|passcode)\b", re.I),
    re.compile(r"(رمز\s*(التحقق|التفعيل|المرور|الدخول)|كلمة\s*(السر|المرور)\s*(المؤقتة|لمرة)|الرقم\s*السري\s*المؤقت|رمز\s*لمرة\s*واحدة)"),
    re.compile(r"\b(do\s*not\s*share|لا\s*تشارك)", re.I),
]


def eff_exponent(currency: str) -> int:
    return CURRENCY_EXPONENT.get(currency.upper(), 2)


def normalize_digits(text: str) -> str:
    return text.translate(_ARABIC_DIGITS)


def looks_like_otp(text: str) -> bool:
    t = normalize_digits(text)
    return any(p.search(t) for p in OTP_PATTERNS)


def to_minor(amount: str, currency: str) -> int | None:
    """Exact decimal → integer minor units. '1,234.500' KWD → 1234500. Never uses float."""
    s = normalize_digits(amount).strip().replace(",", "").replace(" ", "")
    if not re.fullmatch(r"\d+(\.\d+)?", s):
        return None
    try:
        d = Decimal(s)
    except InvalidOperation:
        return None
    exp = eff_exponent(currency)
    q = d.scaleb(exp).quantize(Decimal(1), rounding=ROUND_HALF_UP)
    if q != d.scaleb(exp):
        # More decimals than the currency allows: refuse rather than silently round.
        return None
    return int(q)


def normalize_currency(token: str | None) -> str | None:
    if not token:
        return None
    t = normalize_digits(token).strip().upper().rstrip(".")
    if re.fullmatch(r"[A-Z]{3}", t):
        return t
    return CURRENCY_ALIASES.get(token.strip()) or CURRENCY_ALIASES.get(t)


_CARD_LIKE = re.compile(r"(?<!\d)(\d[ -]?){12,19}(?!\d)")
_LONG_DIGITS = re.compile(r"(?<!\d)\d{7,}(?!\d)")
_EMAIL = re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+")
_IBAN = re.compile(r"\bKW\d{2}[A-Z]{4}[0-9A-Z]{22}\b", re.I)


def sanitize(text: str) -> str:
    """Server-side second pass: mask card/account numbers, IBANs, emails, long digit runs."""
    t = normalize_digits(text)
    t = _IBAN.sub("KW**IBAN**", t)
    t = _CARD_LIKE.sub(lambda m: "****" + re.sub(r"\D", "", m.group(0))[-4:], t)
    t = _LONG_DIGITS.sub(lambda m: "***" + m.group(0)[-3:], t)
    t = _EMAIL.sub("***@***", t)
    return t


def evidence_present(text: str, evidence: str | None) -> bool:
    if not evidence:
        return False
    norm_text = re.sub(r"\s+", " ", normalize_digits(text)).lower()
    norm_ev = re.sub(r"\s+", " ", normalize_digits(evidence)).lower().strip()
    return bool(norm_ev) and norm_ev in norm_text
