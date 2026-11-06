FROM python:3.12-slim
WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
EXPOSE 8080
# Settings come from the environment: docker run --env-file .env -p 8080:8080 clikgate-sample-backend
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
