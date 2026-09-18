def _signup_and_token(client, username="alice"):
    r = client.post("/api/v1/auth/signup", json={"username": username, "password": "password123"})
    return r.json()["token"]


def _auth(token):
    return {"Authorization": f"Bearer {token}"}


def test_list_trips_empty(client):
    token = _signup_and_token(client)
    r = client.get("/api/v1/trips", headers=_auth(token))
    assert r.status_code == 200
    assert r.json() == []


def test_create_trip(client):
    token = _signup_and_token(client)
    r = client.post("/api/v1/trips", headers=_auth(token), json={
        "destination": "Paris", "startDate": "2024-06-15",
        "endDate": "2024-06-20", "tripType": "solo",
    })
    assert r.status_code == 201
    assert r.json()["destination"] == "Paris"


def test_create_trip_end_before_start(client):
    token = _signup_and_token(client)
    r = client.post("/api/v1/trips", headers=_auth(token), json={
        "destination": "Paris", "startDate": "2024-06-20",
        "endDate": "2024-06-15", "tripType": "solo",
    })
    assert r.status_code == 422


def test_get_trip(client):
    token = _signup_and_token(client)
    trip_id = client.post("/api/v1/trips", headers=_auth(token), json={
        "destination": "Paris", "startDate": "2024-06-15",
        "endDate": "2024-06-17", "tripType": "couple",
    }).json()["id"]
    r = client.get(f"/api/v1/trips/{trip_id}", headers=_auth(token))
    assert r.status_code == 200
    assert r.json()["activities"] == []


def test_get_trip_wrong_user(client):
    token_a = _signup_and_token(client, "alice")
    token_b = _signup_and_token(client, "bob")
    trip_id = client.post("/api/v1/trips", headers=_auth(token_a), json={
        "destination": "Paris", "startDate": "2024-06-15",
        "endDate": "2024-06-17", "tripType": "solo",
    }).json()["id"]
    r = client.get(f"/api/v1/trips/{trip_id}", headers=_auth(token_b))
    assert r.status_code == 404


def test_delete_trip(client):
    token = _signup_and_token(client)
    trip_id = client.post("/api/v1/trips", headers=_auth(token), json={
        "destination": "Paris", "startDate": "2024-06-15",
        "endDate": "2024-06-17", "tripType": "solo",
    }).json()["id"]
    r = client.delete(f"/api/v1/trips/{trip_id}", headers=_auth(token))
    assert r.status_code == 204
    r2 = client.get(f"/api/v1/trips/{trip_id}", headers=_auth(token))
    assert r2.status_code == 404


def test_delete_trip_wrong_user(client):
    token_a = _signup_and_token(client, "alice")
    token_b = _signup_and_token(client, "bob")
    trip_id = client.post("/api/v1/trips", headers=_auth(token_a), json={
        "destination": "Paris", "startDate": "2024-06-15",
        "endDate": "2024-06-17", "tripType": "solo",
    }).json()["id"]
    r = client.delete(f"/api/v1/trips/{trip_id}", headers=_auth(token_b))
    assert r.status_code == 404


def test_list_trips_only_own(client):
    token_a = _signup_and_token(client, "alice")
    token_b = _signup_and_token(client, "bob")
    client.post("/api/v1/trips", headers=_auth(token_a), json={
        "destination": "Paris", "startDate": "2024-06-15",
        "endDate": "2024-06-17", "tripType": "solo",
    })
    r = client.get("/api/v1/trips", headers=_auth(token_b))
    assert r.json() == []
