def _signup_and_token(client, username="alice"):
    r = client.post("/api/v1/auth/signup", json={"username": username, "password": "password123"})
    return r.json()["token"]


def _auth(token):
    return {"Authorization": f"Bearer {token}"}


def _create_trip(client, token, start="2024-06-15", end="2024-06-17"):
    return client.post("/api/v1/trips", headers=_auth(token), json={
        "destination": "Paris", "startDate": start,
        "endDate": end, "tripType": "solo",
    }).json()["id"]


def test_add_activity(client):
    token = _signup_and_token(client)
    trip_id = _create_trip(client, token)
    r = client.post(
        f"/api/v1/trips/{trip_id}/activities",
        headers=_auth(token),
        json={"dayIndex": 1, "text": "Visit the Eiffel Tower"},
    )
    assert r.status_code == 201
    assert r.json()["text"] == "Visit the Eiffel Tower"


def test_add_activity_invalid_day_index(client):
    token = _signup_and_token(client)
    trip_id = _create_trip(client, token)  # 3-day trip: days 1, 2, 3
    r = client.post(
        f"/api/v1/trips/{trip_id}/activities",
        headers=_auth(token),
        json={"dayIndex": 4, "text": "Out of range"},
    )
    assert r.status_code == 400


def test_activity_appears_in_trip_detail(client):
    token = _signup_and_token(client)
    trip_id = _create_trip(client, token)
    client.post(
        f"/api/v1/trips/{trip_id}/activities",
        headers=_auth(token),
        json={"dayIndex": 1, "text": "Eiffel Tower"},
    )
    r = client.get(f"/api/v1/trips/{trip_id}", headers=_auth(token))
    assert len(r.json()["activities"]) == 1


def test_update_activity(client):
    token = _signup_and_token(client)
    trip_id = _create_trip(client, token)
    act_id = client.post(
        f"/api/v1/trips/{trip_id}/activities",
        headers=_auth(token),
        json={"dayIndex": 1, "text": "Old text"},
    ).json()["id"]
    r = client.put(
        f"/api/v1/trips/{trip_id}/activities/{act_id}",
        headers=_auth(token),
        json={"text": "New text"},
    )
    assert r.status_code == 200
    assert r.json()["text"] == "New text"


def test_delete_activity(client):
    token = _signup_and_token(client)
    trip_id = _create_trip(client, token)
    act_id = client.post(
        f"/api/v1/trips/{trip_id}/activities",
        headers=_auth(token),
        json={"dayIndex": 1, "text": "To delete"},
    ).json()["id"]
    r = client.delete(
        f"/api/v1/trips/{trip_id}/activities/{act_id}",
        headers=_auth(token),
    )
    assert r.status_code == 204
    detail = client.get(f"/api/v1/trips/{trip_id}", headers=_auth(token)).json()
    assert detail["activities"] == []


def test_add_activity_wrong_user(client):
    token_a = _signup_and_token(client, "alice")
    token_b = _signup_and_token(client, "bob")
    trip_id = _create_trip(client, token_a)
    r = client.post(
        f"/api/v1/trips/{trip_id}/activities",
        headers=_auth(token_b),
        json={"dayIndex": 1, "text": "Unauthorized"},
    )
    assert r.status_code == 404


def test_add_activity_empty_text(client):
    token = _signup_and_token(client)
    trip_id = _create_trip(client, token)
    r = client.post(
        f"/api/v1/trips/{trip_id}/activities",
        headers=_auth(token),
        json={"dayIndex": 1, "text": ""},
    )
    assert r.status_code == 422


def test_add_activity_text_too_long(client):
    token = _signup_and_token(client)
    trip_id = _create_trip(client, token)
    r = client.post(
        f"/api/v1/trips/{trip_id}/activities",
        headers=_auth(token),
        json={"dayIndex": 1, "text": "x" * 301},
    )
    assert r.status_code == 422
