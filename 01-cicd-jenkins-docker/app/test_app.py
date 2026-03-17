import json
import pytest
from app import app


@pytest.fixture
def client():
    app.config["TESTING"] = True
    with app.test_client() as c:
        yield c


def test_health_returns_200(client):
    res = client.get("/health")
    assert res.status_code == 200


def test_health_payload(client):
    res = client.get("/health")
    data = res.get_json()
    assert data["status"] == "ok"
    assert "version" in data


def test_home_returns_200(client):
    res = client.get("/")
    assert res.status_code == 200


def test_home_payload(client):
    res = client.get("/")
    data = res.get_json()
    assert "message" in data
    assert "CI/CD" in data["message"]
