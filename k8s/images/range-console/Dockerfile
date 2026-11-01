FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1
WORKDIR /app
COPY console.py /app/console.py
COPY ui.html /app/ui.html
USER 10001
CMD ["python","/app/console.py"]
