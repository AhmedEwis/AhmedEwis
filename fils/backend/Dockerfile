# syntax=docker/dockerfile:1
FROM python:3.13-slim AS base
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
WORKDIR /app
RUN groupadd --system --gid 10001 fils && useradd --system --uid 10001 --gid fils --home /app fils
COPY requirements.txt .
# Optional build secret "pip_ca": extra CA bundle for TLS-intercepting build proxies (never stored in the image).
RUN --mount=type=secret,id=pip_ca,target=/run/secrets/pip_ca,required=false \
    sh -c 'if [ -s /run/secrets/pip_ca ]; then export PIP_CERT=/run/secrets/pip_ca; fi; pip install --no-cache-dir -r requirements.txt'
COPY --chown=fils:fils alembic.ini ./
COPY --chown=fils:fils alembic ./alembic
COPY --chown=fils:fils fils_api ./fils_api
USER 10001
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=3s --retries=3 CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/healthz',timeout=2).status==200 else 1)"
# API by default; the worker runs the same image with: python -m fils_api.worker
CMD ["uvicorn", "fils_api.main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers", "--forwarded-allow-ips", "*", "--no-server-header"]
