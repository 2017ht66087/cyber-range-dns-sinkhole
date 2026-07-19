FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1
WORKDIR /app
RUN pip install --no-cache-dir dnslib==0.9.24
COPY dns.py /app/dns.py
CMD ["python","/app/dns.py"]
