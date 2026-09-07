FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY main.py ./
COPY maoguai ./maoguai

ENTRYPOINT ["python", "/app/main.py"]
