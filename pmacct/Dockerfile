FROM python:3.11-slim
RUN pip install --no-cache-dir prometheus-client
WORKDIR /app
COPY flow_exporter.py .
CMD ["python3", "-u", "flow_exporter.py"]
