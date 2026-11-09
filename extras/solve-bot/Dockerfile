FROM python:3.12-alpine
WORKDIR /app
COPY bot.py /app/bot.py
RUN adduser -D -u 1000 bot && mkdir /data && chown bot:bot /data
USER bot
ENV PYTHONUNBUFFERED=1
CMD ["python", "/app/bot.py"]
