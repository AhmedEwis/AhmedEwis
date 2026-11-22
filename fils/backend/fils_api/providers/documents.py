"""OCR provider abstraction for statement images (Azure AI Document Intelligence 'prebuilt-read')."""
from __future__ import annotations

import time
from typing import Protocol

import httpx

from ..config import Settings


class ProviderNotConfigured(Exception):
    pass


class OCRProvider(Protocol):
    name: str

    def read_text(self, data: bytes, content_type: str) -> str: ...


class DisabledOCR:
    name = "disabled"

    def read_text(self, data: bytes, content_type: str) -> str:
        raise ProviderNotConfigured("Image statement import needs Azure Document Intelligence configuration")


class AzureDocumentIntelligence:
    name = "azure_document_intelligence"

    def __init__(self, endpoint: str, key: str, client: httpx.Client | None = None):
        self.endpoint = endpoint.rstrip("/")
        self.key = key
        self.client = client or httpx.Client(timeout=30.0)

    def read_text(self, data: bytes, content_type: str) -> str:
        url = f"{self.endpoint}/documentintelligence/documentModels/prebuilt-read:analyze?api-version=2024-11-30"
        r = self.client.post(url, headers={"Ocp-Apim-Subscription-Key": self.key, "Content-Type": content_type}, content=data)
        r.raise_for_status()
        op = r.headers["Operation-Location"]
        for _ in range(30):
            time.sleep(1)
            s = self.client.get(op, headers={"Ocp-Apim-Subscription-Key": self.key})
            s.raise_for_status()
            body = s.json()
            if body.get("status") == "succeeded":
                return body.get("analyzeResult", {}).get("content", "")
            if body.get("status") == "failed":
                raise RuntimeError("document analysis failed")
        raise TimeoutError("document analysis timed out")


def build_ocr(settings: Settings) -> OCRProvider:
    if settings.document_intelligence_endpoint and settings.document_intelligence_key:
        return AzureDocumentIntelligence(settings.document_intelligence_endpoint, settings.document_intelligence_key)
    return DisabledOCR()
