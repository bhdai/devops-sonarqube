import pytest
from fastapi.testclient import TestClient

import main
from main import app

client = TestClient(app)


# ==============================================================================
# Fixture: reset in-memory store between tests
# ==============================================================================
#
# All test functions share the same module-level app instance, so the in-memory
# dict would otherwise accumulate state across tests. Resetting here keeps each
# test independent and predictable.


@pytest.fixture(autouse=True)
def reset_store():
    main._items.clear()
    main._next_id = 1
    yield
    main._items.clear()
    main._next_id = 1


# ==============================================================================
# Infrastructure endpoints
# ==============================================================================


def test_health():
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_root():
    response = client.get("/")
    assert response.status_code == 200
    assert response.json() == {"message": "DevOps SonarQube FastAPI Pipeline"}


# ==============================================================================
# Item CRUD
# ==============================================================================


def test_list_items_empty():
    response = client.get("/items")
    assert response.status_code == 200
    assert response.json() == []


def test_create_item():
    response = client.post("/items", json={"name": "deploy pipeline"})
    assert response.status_code == 201
    data = response.json()
    assert data["name"] == "deploy pipeline"
    assert isinstance(data["id"], int)


def test_create_multiple_items_have_unique_ids():
    ids = [
        client.post("/items", json={"name": f"item-{i}"}).json()["id"]
        for i in range(3)
    ]
    assert len(set(ids)) == 3


def test_list_items_after_creation():
    client.post("/items", json={"name": "alpha"})
    client.post("/items", json={"name": "beta"})
    response = client.get("/items")
    assert response.status_code == 200
    names = [item["name"] for item in response.json()]
    assert "alpha" in names
    assert "beta" in names


def test_get_item():
    item_id = client.post("/items", json={"name": "sonarqube"}).json()["id"]
    response = client.get(f"/items/{item_id}")
    assert response.status_code == 200
    assert response.json() == {"id": item_id, "name": "sonarqube"}


def test_get_item_not_found():
    response = client.get("/items/99999")
    assert response.status_code == 404
    assert response.json()["detail"] == "Item not found"


def test_delete_item():
    item_id = client.post("/items", json={"name": "to-delete"}).json()["id"]
    response = client.delete(f"/items/{item_id}")
    assert response.status_code == 204
    # Verify it's gone
    assert client.get(f"/items/{item_id}").status_code == 404


def test_delete_item_not_found():
    response = client.delete("/items/99999")
    assert response.status_code == 404
    assert response.json()["detail"] == "Item not found"
