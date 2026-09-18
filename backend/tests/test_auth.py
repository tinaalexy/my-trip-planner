def test_signup_success(client):
    r = client.post("/api/v1/auth/signup", json={"username": "alice", "password": "password123"})
    assert r.status_code == 201
    data = r.json()
    assert "token" in data
    assert data["user"]["username"] == "alice"


def test_signup_duplicate_username(client):
    client.post("/api/v1/auth/signup", json={"username": "alice", "password": "password123"})
    r = client.post("/api/v1/auth/signup", json={"username": "alice", "password": "password123"})
    assert r.status_code == 409


def test_signup_short_username(client):
    r = client.post("/api/v1/auth/signup", json={"username": "ab", "password": "password123"})
    assert r.status_code == 422


def test_signup_short_password(client):
    r = client.post("/api/v1/auth/signup", json={"username": "alice", "password": "short"})
    assert r.status_code == 422


def test_login_success(client):
    client.post("/api/v1/auth/signup", json={"username": "alice", "password": "password123"})
    r = client.post("/api/v1/auth/login", json={"username": "alice", "password": "password123"})
    assert r.status_code == 200
    assert "token" in r.json()


def test_login_wrong_password(client):
    client.post("/api/v1/auth/signup", json={"username": "alice", "password": "password123"})
    r = client.post("/api/v1/auth/login", json={"username": "alice", "password": "wrongpass"})
    assert r.status_code == 401


def test_login_unknown_user(client):
    r = client.post("/api/v1/auth/login", json={"username": "nobody", "password": "password123"})
    assert r.status_code == 401
