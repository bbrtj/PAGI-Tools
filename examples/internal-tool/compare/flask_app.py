# The same task board in Flask, for comparison with app.pl. Flask has
# templates, flash and static files built in; CSRF is the Flask-WTF
# extension, done by hand here so the two apps need the same extras.
#
# Run:  pip install flask
#       flask --app flask_app run --port 8000

import hmac, os, re, secrets
from flask import Flask, abort, flash, redirect, render_template, request, session, url_for

app = Flask(__name__)
app.secret_key = os.environ.get("SECRET_KEY", "dev")
BOARD = {"next": 1, "list": []}


def csrf_token():
    return session.setdefault("csrf_token", secrets.token_urlsafe(32))


app.jinja_env.globals["csrf_token"] = csrf_token


def check_csrf():
    if not hmac.compare_digest(request.form.get("csrf_token", ""), session.get("csrf_token", "-")):
        abort(403, "CSRF token validation failed")


def validate(form):
    errors = {}
    title = form.get("title", "").strip()
    if not title:
        errors["title"] = "A title is required."
    elif len(title) > 80:
        errors["title"] = "Keep the title under 80 characters."
    due = form.get("due", "")
    if due and not re.fullmatch(r"\d{4}-\d{2}-\d{2}", due):
        errors["due"] = "Use YYYY-MM-DD."
    return {"title": title, "due": due}, errors


@app.get("/")
def index():
    return render_template("index.html", tasks=BOARD["list"], form={}, errors={})


@app.post("/tasks")
def create():
    check_csrf()
    values, errors = validate(request.form)
    if errors:
        return render_template("index.html", tasks=BOARD["list"], form=values, errors=errors), 422
    BOARD["list"].append({"id": BOARD["next"], **values, "done": False})
    BOARD["next"] += 1
    flash(f'Added "{values["title"]}".')
    return redirect(url_for("index"), 303)


@app.post("/tasks/<int:id>/toggle")
def toggle(id):
    check_csrf()
    task = next((t for t in BOARD["list"] if t["id"] == id), None) or abort(404)
    task["done"] = not task["done"]
    flash(("Done: " if task["done"] else "Reopened: ") + task["title"] + ".")
    return redirect(url_for("index"), 303)


@app.post("/tasks/<int:id>/delete")
def delete(id):
    check_csrf()
    before = len(BOARD["list"])
    BOARD["list"] = [t for t in BOARD["list"] if t["id"] != id]
    if len(BOARD["list"]) == before:
        abort(404)
    flash("Deleted.")
    return redirect(url_for("index"), 303)
