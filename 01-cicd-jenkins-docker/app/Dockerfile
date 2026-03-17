# syntax=docker/dockerfile:1
# -----------------------------------------------------------
# Multi-stage build: test stage validates, runtime stage ships
# -----------------------------------------------------------

# Stage 1 — test
FROM python:3.12-slim AS test

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
RUN pytest -q

# Stage 2 — runtime
FROM python:3.12-slim AS runtime

# Run as non-root user
RUN useradd --no-create-home --shell /bin/false appuser

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir Flask==3.0.3 gunicorn==22.0.0

COPY --chown=appuser:appuser . .

USER appuser
EXPOSE 5000

HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:5000/health')" || exit 1

CMD ["gunicorn", "-w", "2", "-b", "0.0.0.0:5000", "--access-logfile", "-", "--error-logfile", "-", "app:app"]
