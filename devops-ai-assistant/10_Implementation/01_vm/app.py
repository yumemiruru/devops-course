from flask import Flask, jsonify
import os

app = Flask(__name__)

@app.route("/")
def index():
    return "<h1>My Training App</h1><p>Status: running</p>"

@app.route("/health")
def health():
    return jsonify({"status": "ok"})

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5000))
    app.run(host="127.0.0.1", port=port)