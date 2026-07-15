"""Minimal Flask fixture exposing an OpenAPI 3.0 spec for the api-contract smoke.
Deliberately robust: every path returns a spec-conformant response and never 500s,
so `schemathesis run` against it is GREEN (proves the CI pipeline, not app bugs)."""

from flask import Flask, jsonify

app = Flask(__name__)

OPENAPI = {
    "openapi": "3.0.3",
    "info": {"title": "Fixture API", "version": "1.0.0"},
    "paths": {
        "/health": {
            "get": {
                "responses": {
                    "200": {
                        "description": "ok",
                        "content": {
                            "application/json": {
                                "schema": {
                                    "type": "object",
                                    "properties": {"status": {"type": "string"}},
                                    "required": ["status"],
                                }
                            }
                        },
                    }
                }
            }
        },
        "/items/{item_id}": {
            "get": {
                "parameters": [
                    {
                        "name": "item_id",
                        "in": "path",
                        "required": True,
                        "schema": {"type": "integer"},
                    }
                ],
                "responses": {
                    "200": {
                        "description": "item",
                        "content": {
                            "application/json": {
                                "schema": {
                                    "type": "object",
                                    "properties": {
                                        "id": {"type": "integer"},
                                        "name": {"type": "string"},
                                    },
                                    "required": ["id", "name"],
                                }
                            }
                        },
                    },
                    "404": {"description": "not found"},
                },
            }
        },
    },
}


@app.get("/openapi.json")
def openapi():
    return jsonify(OPENAPI)


@app.get("/health")
def health():
    return jsonify({"status": "ok"}), 200


@app.get("/items/<int:item_id>")
def get_item(item_id: int):
    # Flask's <int:...> converter already rejects non-integers with 404 (conformant).
    if 1 <= item_id <= 100:
        return jsonify({"id": item_id, "name": f"item-{item_id}"}), 200
    return jsonify({"error": "not found"}), 404


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5005)
