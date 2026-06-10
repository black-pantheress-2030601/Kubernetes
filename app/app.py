from flask import Flask, jsonify, request
import os
import json
from datetime import datetime, timezone

app = Flask(__name__)

DATA_DIR = "/data"
DATA_FILE = os.path.join(DATA_DIR, "entries.json")

# Ensure data directory exists
os.makedirs(DATA_DIR, exist_ok=True)

def load_entries():
    if os.path.exists(DATA_FILE):
        with open(DATA_FILE, 'r') as f:
            return json.load(f)
    return []

def save_entries(entries):
    with open(DATA_FILE, 'w') as f:
        json.dump(entries, f, indent=2)

@app.route("/health")
def health():
    # Check if storage is writable
    try:
        test_file = os.path.join(DATA_DIR, ".health_check")
        with open(test_file, 'w') as f:
            f.write("ok")
        os.remove(test_file)
        storage_ok = True
    except Exception:
        storage_ok = False

    return jsonify(status="ok", storage=storage_ok), 200

@app.route("/")
def index():
    entries = load_entries()
    return jsonify(
        message="Hello from EKS with persistent storage",
        total_entries=len(entries),
        storage_path=DATA_DIR
    ), 200

@app.route("/entries", methods=["GET"])
def get_entries():
    entries = load_entries()
    return jsonify(entries=entries, count=len(entries)), 200

@app.route("/entries", methods=["POST"])
def add_entry():
    data = request.get_json()
    if not data or 'message' not in data:
        return jsonify(error="message field required"), 400

    entries = load_entries()
    entry = {
        "id": len(entries) + 1,
        "message": data['message'],
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "pod": os.environ.get('HOSTNAME', 'unknown')
    }
    entries.append(entry)
    save_entries(entries)

    return jsonify(entry=entry, message="Entry saved to persistent storage"), 201

@app.route("/entries/<int:entry_id>", methods=["DELETE"])
def delete_entry(entry_id):
    entries = load_entries()
    entries = [e for e in entries if e['id'] != entry_id]
    save_entries(entries)
    return jsonify(message=f"Entry {entry_id} deleted"), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)