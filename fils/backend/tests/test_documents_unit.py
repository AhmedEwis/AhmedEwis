from fils_api.services.documents import extract_csv, extract_lines, parse_date


def test_parse_dates():
    assert parse_date("22/11/2026") == "2026-11-22"
    assert parse_date("2026-11-05 TALABAT") == "2026-11-05"
    assert parse_date("05 Nov 26") == "2026-11-05"
    assert parse_date("٢٢/١١/٢٠٢٦") == "2026-11-22"
    assert parse_date("31/02/2026") is None


def test_statement_lines_take_amount_not_balance():
    text = "22/11/2026 POS TALABAT KUWAIT 5.250 1,234.500\n23/11/2026 SALARY CREDIT 1,500.000 2,734.500\nPage 1 of 2"
    rows = extract_lines(text)
    assert [r["amount_minor"] for r in rows] == [5250, 1_500_000]
    assert rows[0]["direction"] == "debit" and rows[1]["direction"] == "credit"
    assert all(r["needs_review"] for r in rows)


def test_csv_signed_amount_column_and_arabic_headers():
    data = "التاريخ,البيان,المبلغ\n2026-11-22,طلبات,-5.250\n2026-11-25,راتب,1500.000\n".encode()
    rows = extract_csv(data)
    assert rows[0]["amount_minor"] == 5250 and rows[0]["direction"] == "debit" and rows[0]["description"] == "طلبات"
    assert rows[1]["direction"] == "credit"
