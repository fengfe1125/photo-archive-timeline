#!/usr/bin/env python3
"""Real local Auth/PostgREST tests. Refuses non-loopback deployments; never logs credentials."""
import concurrent.futures
import json
import os
import subprocess
import unittest
import urllib.error
import urllib.request
import uuid
from urllib.parse import urlparse


def uid():
    return str(uuid.uuid4())


class BackendTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cli = os.environ.get("SUPABASE_CLI", "supabase")
        raw = subprocess.run([cli, "status", "-o", "json"], check=True, capture_output=True, text=True)
        cls.config = json.loads(raw.stdout)
        cls.url = cls.config["API_URL"]
        if urlparse(cls.url).hostname not in ("127.0.0.1", "localhost"):
            raise RuntimeError("Integration tests only run against loopback local Supabase")
        cls.key = cls.config.get("PUBLISHABLE_KEY") or cls.config["ANON_KEY"]
        cls.admin = cls.config["SERVICE_ROLE_KEY"]
        cls.users = []
        for _ in range(2):
            email = f"archive-{uid()}@example.test"
            status, created = cls.http("POST", "/auth/v1/admin/users", {"email": email, "password": uid() + "Aa!7", "email_confirm": True}, cls.admin, cls.admin)
            # Request a separate random password without printing it.
            assert status == 200, (status, created)
            password = uid() + "Aa!7"
            status, _ = cls.http("PUT", "/auth/v1/admin/users/" + created["id"], {"password": password}, cls.admin, cls.admin)
            assert status == 200
            status, signed = cls.http("POST", "/auth/v1/token?grant_type=password", {"email": email, "password": password})
            assert status == 200
            cls.users.append((created["id"], signed["access_token"]))
        cls.a, cls.b = cls.users

    @classmethod
    def tearDownClass(cls):
        for user, _ in cls.users:
            status, result = cls.http("DELETE", "/auth/v1/admin/users/" + user, token=cls.admin, key=cls.admin)
            assert status == 200, (status, result)

    @classmethod
    def http(cls, method, path, body=None, token=None, key=None):
        headers = {"apikey": key or cls.key, "Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        req = urllib.request.Request(cls.url + path, data=None if body is None else json.dumps(body).encode(), headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=30) as result:
                data = result.read()
                return result.status, json.loads(data) if data else None
        except urllib.error.HTTPError as error:
            data = error.read()
            error.close()
            try:
                return error.code, json.loads(data)
            except json.JSONDecodeError:
                return error.code, {"message": data.decode()}

    def push(self, entity, entity_id, payload, base=0, deleted=False, operation=None, token=None, resolving=None):
        op = {"id": operation or uid(), "entity": entity, "entityID": entity_id, "baseVersion": base, "deleted": deleted, "payload": payload}
        if resolving:
            op["resolving"] = resolving
        return self.http("POST", "/rest/v1/rpc/archive_push", {"p_operation": op}, token or self.a[1])

    def media(self, token=None, cloud=None):
        media = uid()
        payload = {"kind": "photo"}
        if cloud:
            payload["cloudIdentifier"] = cloud
        status, result = self.push("media", media, payload, token=token)
        self.assertEqual(status, 200, result)
        return result["record"]["id"]

    def story(self, media, title="Trip"):
        return {"title": title, "description": "User-authored note", "mediaIDs": [media], "coverID": media}

    def test_01_auth_rls_and_privacy(self):
        media = self.media()
        for table in ("archive_media", "archive_stories", "archive_story_items", "archive_corrections", "archive_heads", "archive_changes", "archive_receipts", "archive_conflicts"):
            status, _ = self.http("GET", f"/rest/v1/{table}?select=*")
            self.assertIn(status, (401, 403), table)
            status, rows = self.http("GET", f"/rest/v1/{table}?user_id=eq.{self.a[0]}", token=self.b[1])
            self.assertEqual((status, rows), (200, []), table)
        status, _ = self.http("POST", "/rest/v1/archive_media", {"user_id": self.a[0], "id": uid(), "kind": "photo"}, self.a[1])
        self.assertEqual(status, 403)
        status, _ = self.push("story", uid(), self.story(media), token=self.b[1])
        self.assertEqual(status, 403)
        for key in ("localIdentifier", "originalDay", "originalPlace", "filePath", "imageBytes", "user_id"):
            status, _ = self.push("media", uid(), {"kind": "photo", key: "must-not-upload"})
            self.assertEqual(status, 400, key)

    def test_02_receipt_retry_and_immutable_id(self):
        media, operation = uid(), uid()
        first = self.push("media", media, {"kind": "photo"}, operation=operation)
        repeated = self.push("media", media, {"kind": "photo"}, operation=operation)
        self.assertEqual(first, repeated)
        self.assertEqual(first[1]["record"]["version"], 1)
        changed = self.push("media", media, {"kind": "video"}, operation=operation)
        self.assertEqual(changed[0], 400)

    def test_03_conflict_resolution_and_delete(self):
        media, story = self.media(), uid()
        self.assertEqual(self.push("story", story, self.story(media))[0], 200)
        with concurrent.futures.ThreadPoolExecutor(2) as executor:
            results = list(executor.map(lambda title: self.push("story", story, self.story(media, title), base=1), ["Device A", "Device B"]))
        self.assertTrue(all(status == 200 for status, _ in results), results)
        self.assertEqual(sorted(result["status"] for _, result in results), ["accepted", "conflict"])
        conflict = next(result["conflict"] for _, result in results if result["status"] == "conflict")
        self.assertNotEqual(conflict["local"]["payload"]["title"], conflict["remote"]["payload"]["title"])
        status, resolved = self.push("story", story, conflict["local"]["payload"], base=2, resolving=conflict["id"])
        self.assertEqual((status, resolved["status"]), (200, "accepted"))
        status, removed = self.push("story", story, {}, base=3, deleted=True)
        self.assertEqual((status, removed["record"]["deleted"]), (200, True))
        status, stale = self.push("story", story, self.story(media, "Offline stale"), base=2)
        self.assertEqual(stale["status"], "conflict")
        self.assertTrue(stale["remote"]["deleted"] if "remote" in stale else stale["conflict"]["remote"]["deleted"])

    def test_04_atomic_story_and_owner_links(self):
        media, story = self.media(), uid()
        invalid = self.story(media); invalid["coverID"] = uid()
        self.assertEqual(self.push("story", story, invalid)[0], 400)
        status, rows = self.http("GET", f"/rest/v1/archive_stories?id=eq.{story}", token=self.a[1])
        self.assertEqual(rows, [])
        valid = self.story(media)
        self.assertEqual(self.push("story", story, valid)[1]["record"]["version"], 1)
        status, items = self.http("GET", f"/rest/v1/archive_story_items?story_id=eq.{story}", token=self.a[1])
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["media_id"], media)

    def test_05_explicit_clear_original_and_restore(self):
        media = self.media()
        correction = {"description": "Caption only", "dayMode": "original", "placeMode": "original"}
        status, result = self.push("correction", media, correction)
        self.assertEqual((status, result["status"]), (200, "accepted"))
        invalid = dict(correction, place={"name": "Leaked original GPS", "latitude": 1, "longitude": 1})
        self.assertEqual(self.push("correction", media, invalid, base=1)[0], 400)
        invalid = dict(correction, dayMode="value", day={"year": 2023, "month": 2, "day": 29})
        self.assertEqual(self.push("correction", media, invalid, base=1)[0], 400)
        clear = dict(correction, dayMode="clear", placeMode="clear")
        self.assertEqual(self.push("correction", media, clear, base=1)[0], 200)
        restored = self.push("correction", media, {}, base=2, deleted=True)
        self.assertTrue(restored[1]["record"]["deleted"])

    def test_06_canonical_photo_identity(self):
        cloud = "synthetic-cloud-" + uid()
        first = self.media(cloud=cloud)
        status, second = self.push("media", uid(), {"kind": "photo", "cloudIdentifier": cloud})
        self.assertEqual((status, second["status"], second["record"]["id"]), (200, "canonical", first))
        other = self.media(token=self.b[1], cloud=cloud)
        self.assertNotEqual(first, other)

    def test_07_pagination_and_committed_sequences(self):
        def add(_):
            return self.push("media", uid(), {"kind": "photo"})
        with concurrent.futures.ThreadPoolExecutor(8) as executor:
            results = list(executor.map(add, range(205)))
        self.assertTrue(all(status == 200 for status, _ in results))
        cursor, sequences = 0, []
        while True:
            status, page = self.http("POST", "/rest/v1/rpc/archive_pull", {"p_after": cursor}, self.a[1])
            self.assertEqual(status, 200)
            sequences.extend(change["sequence"] for change in page["changes"])
            cursor = page["cursor"]
            if not page["hasMore"]:
                break
        self.assertGreater(len(sequences), 205)
        self.assertEqual(sequences, list(range(1, cursor + 1)))


    def test_08_account_deletion_and_old_token(self):
        status, _ = self.http("POST", "/functions/v1/delete-account", {})
        self.assertEqual(status, 401)
        # An injected user_id must never select another person's account.
        status, result = self.http("POST", "/functions/v1/delete-account", {"user_id": self.b[0]}, self.a[1])
        self.assertEqual((status, result), (200, {"deleted": True}))
        type(self).users = [self.b]
        status, _ = self.http("GET", "/auth/v1/admin/users/" + self.b[0], token=self.admin, key=self.admin)
        self.assertEqual(status, 200)
        status, _ = self.push("media", uid(), {"kind": "photo"}, token=self.a[1])
        self.assertIn(status, (401, 403))
        status, rows = self.http("GET", "/rest/v1/archive_media", token=self.a[1])
        self.assertTrue(status in (401, 403) or rows == [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
