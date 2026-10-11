# The same webhook receiver in Flask, for comparison with app.pl.
#
# Run:  pip install flask
#       WEBHOOK_SECRET=s3cret flask --app flask_app run --port 8000

import hmac, hashlib, json, os, time
from flask import Flask, request, jsonify, abort

SECRET = os.environ.get("WEBHOOK_SECRET", "s3cret").encode()
LOG = os.environ.get("WEBHOOK_LOG", "/tmp/deliveries.jsonl")
app = Flask(__name__)


def signature_ok(raw):
    given = request.headers.get("X-Hub-Signature-256")
    if given is None:
        return False
    want = "sha256=" + hmac.new(SECRET, raw, hashlib.sha256).hexdigest()
    return hmac.compare_digest(given, want)


def deliveries():
    try:
        with open(LOG) as fh:
            return [json.loads(line) for line in fh]
    except FileNotFoundError:
        return []


@app.post("/hooks/github")
def receive():
    raw = request.get_data()
    if not signature_ok(raw):
        return jsonify(error="bad signature"), 401
    payload = request.get_json(force=True)  # a 400 if it is not JSON
    delivery = {
        "id": request.headers.get("X-GitHub-Delivery", str(int(time.time()))),
        "event": request.headers.get("X-GitHub-Event", "unknown"),
        "received": int(time.time()),
        "payload": payload,
    }
    with open(LOG, "a") as fh:
        fh.write(json.dumps(delivery, sort_keys=True) + "\n")
    return jsonify(ok=1, id=delivery["id"]), 202


@app.get("/")
def status_page():
    recent = list(reversed(deliveries()[-10:]))
    rows = "".join(
        f"<li><code>{d['event']}</code> {d['id']} <small>{time.ctime(d['received'])}</small></li>"
        for d in recent
    )
    return f"""<h1>Webhook receiver</h1>
<p>{len(deliveries())} deliveries logged to <code>{LOG}</code>.</p>
<ul>{rows}</ul>
<p><a href="/deliveries.json">JSON</a></p>
"""


@app.get("/deliveries.json")
def deliveries_json():
    n = request.args.get("n", 50, type=int)
    return jsonify(deliveries()[-n:])
