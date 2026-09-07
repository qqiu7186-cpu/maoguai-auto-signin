FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN groupadd --system --gid 10001 maoguai \
    && useradd --system --uid 10001 --gid maoguai --create-home \
        --shell /usr/sbin/nologin maoguai

WORKDIR /app

COPY --chown=maoguai:maoguai main.py ./
COPY --chown=maoguai:maoguai maoguai ./maoguai

RUN mkdir /app/data && chown maoguai:maoguai /app/data

USER maoguai

ENTRYPOINT ["python", "/app/main.py"]
