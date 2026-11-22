"""Upload validation by magic bytes — the client-declared type is never trusted."""
from __future__ import annotations

from ..errors import APIError


def sniff_upload(data: bytes, filename: str, declared_type: str) -> tuple[str, str]:
    if not data:
        raise APIError(422, "empty_file", "File is empty")
    if data.startswith(b"%PDF-"):
        if b"/JavaScript" in data or b"/JS " in data or b"/Launch" in data or b"/EmbeddedFile" in data:
            raise APIError(422, "unsafe_pdf", "PDF contains active content and was rejected")
        return "pdf", "application/pdf"
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image", "image/png"
    if data.startswith(b"\xff\xd8\xff"):
        return "image", "image/jpeg"
    if data[4:12] in (b"ftypheic", b"ftypheix", b"ftypmif1"):
        return "image", "image/heic"
    name = filename.lower()
    if name.endswith(".csv") or declared_type in ("text/csv", "application/vnd.ms-excel", "text/plain"):
        if b"\x00" in data[:4096]:
            raise APIError(422, "invalid_csv", "CSV contains binary data")
        try:
            data.decode("utf-8-sig")
        except UnicodeDecodeError:
            try:
                data.decode("cp1256")
            except UnicodeDecodeError as e:
                raise APIError(422, "invalid_csv", "CSV encoding not supported") from e
        return "csv", "text/csv"
    raise APIError(415, "unsupported_file_type", "Only PDF, CSV, PNG, JPEG and HEIC files are accepted")
