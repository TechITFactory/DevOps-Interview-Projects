import os
import logging
from flask import Flask, jsonify

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger(__name__)

app = Flask(__name__)

APP_VERSION = os.getenv("APP_VERSION", "1.0.0")


@app.get("/health")
def health():
    logger.info("health check requested")
    return jsonify({"status": "ok", "version": APP_VERSION}), 200


@app.get("/")
def home():
    logger.info("home endpoint requested")
    return jsonify({"message": "CI/CD with Jenkins + Docker", "version": APP_VERSION}), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
