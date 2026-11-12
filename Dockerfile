# Python 3.11: the pinned Flask 2.0 / Werkzeug 2.0 / pymongo 3.12 versions do not support newer Pythons.
FROM python:3.11-slim

WORKDIR /app

# Install dependencies first so this layer is cached when only app code changes.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

# Do not run as root inside the container.
USER nobody

EXPOSE 5000
CMD ["python", "app.py"]
