import os

from flask import Flask, jsonify

app = Flask(__name__)
APP_SHA = os.environ.get("APP_SHA", "deadbeefcafe")


@app.get("/health")
def health():
    # C2 contract: expose the running git sha
    return jsonify(status="ok", sha=APP_SHA)


@app.get("/")
def index():
    return "<h1 id='title'>ADZA e2e fixture</h1>", 200
