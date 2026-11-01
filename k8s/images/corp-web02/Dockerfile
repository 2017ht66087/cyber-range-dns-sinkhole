FROM python:3.12-alpine
RUN apk add --no-cache postgresql16-client mariadb-client \
 && adduser -D -u 10001 web
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
WORKDIR /app
COPY app.py /app/app.py
USER 10001
EXPOSE 8080
CMD ["python", "/app/app.py"]
