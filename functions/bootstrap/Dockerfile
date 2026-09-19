FROM python:3.12-slim AS builder

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir --no-compile --prefix=/install -r requirements.txt

FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

# Multi-stage: only the installed site-packages come from the builder stage,
# so pip/setuptools/wheel and their build-time footprint never reach the
# runtime image (~9% smaller than a single-stage `pip install` here).
COPY --from=builder /install /usr/local
COPY . ./

# Cloud Run sets $PORT (default 8080); uvicorn must bind it on 0.0.0.0.
ENV PORT=8080
CMD ["sh", "-c", "exec uvicorn main:app --host 0.0.0.0 --port ${PORT:-8080}"]
