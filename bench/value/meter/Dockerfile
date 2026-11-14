# olivium-bench-meter:v1
FROM python:3.12
LABEL olivium-bench="1"
RUN useradd --uid 1002 --create-home --shell /usr/sbin/nologin meter \
    && mkdir -p /app /data && chown meter:meter /data
COPY meter.py prices.json /app/
USER meter
WORKDIR /data
ENTRYPOINT ["python3", "-I", "/app/meter.py"]
