"""Small PostgreSQL-backed URL shortener."""
import logging
import os
import secrets
import string
import threading
import time

import psycopg
from flask import Flask, Response, jsonify, redirect, request
from psycopg.rows import dict_row


def db_config():
    return {
        "host": os.environ["DB_HOST"],
        "port": int(os.environ.get("DB_PORT", "5432")),
        "dbname": os.environ["DB_NAME"],
        "user": os.environ["DB_USER"],
        "password": os.environ["DB_PASSWORD"],
        "connect_timeout": 3,
    }


def connect():
    return psycopg.connect(**db_config(), row_factory=dict_row)


def initialize_database():
    with connect() as connection:
        connection.execute(
            "CREATE TABLE IF NOT EXISTS links ("
            "code VARCHAR(16) PRIMARY KEY, url TEXT NOT NULL, "
            "created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), "
            "clicks BIGINT NOT NULL DEFAULT 0)"
        )


app = Flask(__name__)
logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO").upper())
links_created = 0
redirects_succeeded = 0
redirects_missing = 0
db_initialized = False
db_init_lock = threading.Lock()


def container_memory_bytes():
    try:
        with open("/sys/fs/cgroup/memory.current", encoding="ascii") as memory_file:
            return int(memory_file.read().strip())
    except (OSError, ValueError):
        return 0


@app.before_request
def begin_request():
    request.started_at = time.perf_counter()


@app.after_request
def log_request(response):
    elapsed_ms = (time.perf_counter() - request.started_at) * 1000
    app.logger.info("%s %s %s %.2fms", request.method, request.path,
                    response.status_code, elapsed_ms)
    return response


@app.post("/api/links")
def create_link():
    global links_created
    payload = request.get_json(silent=True) or {}
    url = payload.get("url")
    if not isinstance(url, str) or not url.startswith(("http://", "https://")):
        return jsonify(error="url must be an http(s) URL"), 400
    for _ in range(5):
        code = "".join(secrets.choice(string.ascii_letters + string.digits)
                       for _ in range(7))
        try:
            with connect() as connection:
                connection.execute("INSERT INTO links (code, url) VALUES (%s, %s)",
                                   (code, url))
            links_created += 1
            return jsonify(code=code), 201
        except psycopg.errors.UniqueViolation:
            continue
    return jsonify(error="could not allocate a unique code"), 503


@app.get("/r/<code>")
def follow_link(code):
    global redirects_succeeded, redirects_missing
    with connect() as connection:
        row = connection.execute("UPDATE links SET clicks = clicks + 1 WHERE code = %s "
                                 "RETURNING url", (code,)).fetchone()
    if row is None:
        redirects_missing += 1
        return jsonify(error="link not found"), 404
    redirects_succeeded += 1
    return redirect(row["url"], code=302)


@app.get("/healthz")
def health():
    return "ok\n", 200, {"Content-Type": "text/plain; charset=utf-8"}


@app.get("/readyz")
def ready():
    global db_initialized
    try:
        if not db_initialized:
            with db_init_lock:
                if not db_initialized:
                    initialize_database()
                    db_initialized = True
        with connect() as connection:
            connection.execute("SELECT 1")
        return "ready\n", 200, {"Content-Type": "text/plain; charset=utf-8"}
    except (psycopg.Error, KeyError, ValueError):
        return "database unavailable\n", 503, {"Content-Type": "text/plain; charset=utf-8"}


@app.get("/metrics")
def metrics():
    body = (
        "# HELP shortlink_links_created_total Links created by this process\n"
        "# TYPE shortlink_links_created_total counter\n"
        f"shortlink_links_created_total {links_created}\n"
        "# HELP shortlink_redirects_succeeded_total Successful redirects by this process\n"
        "# TYPE shortlink_redirects_succeeded_total counter\n"
        f"shortlink_redirects_succeeded_total {redirects_succeeded}\n"
        "# HELP shortlink_redirects_missing_total Redirects for unknown codes by this process\n"
        "# TYPE shortlink_redirects_missing_total counter\n"
        f"shortlink_redirects_missing_total {redirects_missing}\n"
        "# HELP shortlink_container_memory_bytes Current cgroup memory usage\n"
        "# TYPE shortlink_container_memory_bytes gauge\n"
        f"shortlink_container_memory_bytes {container_memory_bytes()}\n"
    )
    return Response(body, content_type="text/plain; version=0.0.4; charset=utf-8")
