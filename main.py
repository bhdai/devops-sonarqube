from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

app = FastAPI(title="DevOps Pipeline Demo", version="1.0.0")

# ==============================================================================
# In-memory item store
# ==============================================================================
#
# A simple dict-based store is sufficient for this demo. In production this
# would be backed by a database, but keeping state in-process lets us verify
# every endpoint with zero infrastructure in the test suite.

_items: dict[int, str] = {}
_next_id = 1


# ==============================================================================
# Request / response models
# ==============================================================================


class ItemCreate(BaseModel):
    name: str


class ItemResponse(BaseModel):
    id: int
    name: str


# ==============================================================================
# Routes
# ==============================================================================


@app.get("/health")
def health() -> dict:
    """Liveness probe used by the Dockerfile HEALTHCHECK and the deploy script."""
    return {"status": "ok"}


@app.get("/")
def root() -> dict:
    return {"message": "DevOps SonarQube FastAPI Pipeline"}


@app.get("/items", response_model=list[ItemResponse])
def list_items() -> list[ItemResponse]:
    return [ItemResponse(id=k, name=v) for k, v in _items.items()]


@app.post("/items", response_model=ItemResponse, status_code=201)
def create_item(item: ItemCreate) -> ItemResponse:
    global _next_id
    item_id = _next_id
    _items[item_id] = item.name
    _next_id += 1
    return ItemResponse(id=item_id, name=item.name)


@app.get("/items/{item_id}", response_model=ItemResponse)
def get_item(item_id: int) -> ItemResponse:
    if item_id not in _items:
        raise HTTPException(status_code=404, detail="Item not found")
    return ItemResponse(id=item_id, name=_items[item_id])


@app.delete("/items/{item_id}", status_code=204)
def delete_item(item_id: int) -> None:
    if item_id not in _items:
        raise HTTPException(status_code=404, detail="Item not found")
    del _items[item_id]

