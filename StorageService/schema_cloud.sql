-- Snowfell Storage Service — operational store DDL (design record 03
-- §4/§6.1). This schema lives ONLY in the service's cloud.db. It is
-- never applied to the registry, never bundled, never published:
-- cs_credentials and cs_tokens hold secret-derived material, and the
-- publication filter (design record 01 §2) is absolute.
--
-- The service embeds this DDL (sf_store_open bootstraps an empty DB
-- from it) and versions it via cs_meta.schema_version = 2 (SF-T12h, design §13.10).

PRAGMA foreign_keys = ON;

CREATE TABLE cs_meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
INSERT INTO cs_meta (key, value) VALUES ('schema_version', '2');

CREATE TABLE cs_tenants (
    id INTEGER PRIMARY KEY,
    slug TEXT NOT NULL UNIQUE,
    display_name TEXT NOT NULL,
    state TEXT NOT NULL DEFAULT 'active'
        CHECK (state IN ('active', 'suspended', 'closed')),
    quota_bytes INTEGER NOT NULL DEFAULT -1,
    quota_objects INTEGER NOT NULL DEFAULT -1,
    quota_buckets INTEGER NOT NULL DEFAULT -1,
    contact_note TEXT NOT NULL DEFAULT '',
    provenance TEXT NOT NULL DEFAULT 'service',
    directive TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE cs_logins (
    id INTEGER PRIMARY KEY,
    tenant_id INTEGER NOT NULL REFERENCES cs_tenants (id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    username TEXT NOT NULL,
    display_name TEXT NOT NULL DEFAULT '',
    role TEXT NOT NULL CHECK (role IN ('tenant_admin', 'tenant_user')),
    state TEXT NOT NULL DEFAULT 'active'
        CHECK (state IN ('active', 'disabled')),
    last_login_at TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE (tenant_id, username)
);

-- One credential row per (login, kind). kind 'fido2' is the record-02
-- seam: columns stay NULL for it until R1 lands; nothing in v1 writes
-- or reads a fido2 row.
CREATE TABLE cs_credentials (
    id INTEGER PRIMARY KEY,
    login_id INTEGER NOT NULL REFERENCES cs_logins (id)
        ON UPDATE CASCADE ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK (kind IN ('password', 'fido2')),
    password_salt BLOB,
    password_hash BLOB,
    password_iterations INTEGER,
    password_changed_at TEXT,
    failed_attempts INTEGER NOT NULL DEFAULT 0,
    locked_until TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE (login_id, kind)
);

-- Only SHA-256 digests of tokens are stored (LTD licensing precedent).
-- tenant_id/login_id are NULL for the operator token (scope = all).
CREATE TABLE cs_tokens (
    id INTEGER PRIMARY KEY,
    tenant_id INTEGER REFERENCES cs_tenants (id)
        ON UPDATE CASCADE ON DELETE CASCADE,
    login_id INTEGER REFERENCES cs_logins (id)
        ON UPDATE CASCADE ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK (kind IN ('session', 'api', 'operator')),
    token_sha256 BLOB NOT NULL UNIQUE,
    label TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    expires_at TEXT,
    revoked_at TEXT,
    last_used_at TEXT
);
CREATE INDEX cs_tokens_login ON cs_tokens (login_id);

CREATE TABLE cs_password_resets (
    id INTEGER PRIMARY KEY,
    login_id INTEGER NOT NULL REFERENCES cs_logins (id)
        ON UPDATE CASCADE ON DELETE CASCADE,
    token_sha256 BLOB NOT NULL UNIQUE,
    created_by TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    used_at TEXT
);

CREATE TABLE cs_backends (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    kind TEXT NOT NULL CHECK (kind IN ('filesystem', 's3')),
    config_json TEXT NOT NULL DEFAULT '{}',
    secret_ref TEXT NOT NULL DEFAULT '',
    state TEXT NOT NULL DEFAULT 'active'
        CHECK (state IN ('active', 'disabled')),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);


-- Content-addressable blobs (design §13.2): identity is
-- (tenant_id, sha256) — the per-tenant dedup scope (§13.4). Bytes live
-- through the §7 adapters under the blob's hex digest as the adapter
-- key. refcount is maintained transactionally at every reference
-- create/delete and recomputed by the GC sweep before any deletion.
CREATE TABLE cs_blobs (
    id INTEGER PRIMARY KEY,
    tenant_id INTEGER NOT NULL REFERENCES cs_tenants (id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    sha256 BLOB NOT NULL,
    size_bytes INTEGER NOT NULL,
    backend_id INTEGER NOT NULL REFERENCES cs_backends (id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    refcount INTEGER NOT NULL DEFAULT 0,
    state TEXT NOT NULL DEFAULT 'ok' CHECK (state IN ('ok', 'corrupt')),
    orphaned_at TEXT,
    created_at TEXT NOT NULL,
    last_verified_at TEXT,
    UNIQUE (tenant_id, sha256)
);
CREATE INDEX cs_blobs_tenant ON cs_blobs (tenant_id, state);

CREATE TABLE cs_buckets (
    id INTEGER PRIMARY KEY,
    tenant_id INTEGER NOT NULL REFERENCES cs_tenants (id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    name TEXT NOT NULL,
    backend_id INTEGER NOT NULL REFERENCES cs_backends (id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    quota_bytes INTEGER NOT NULL DEFAULT -1,
    object_count INTEGER NOT NULL DEFAULT 0,
    total_bytes INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE (tenant_id, name)
);

-- tenant_id is denormalized onto the object row deliberately: every
-- object query filters on it directly (design §3.2 walls 2-3).
CREATE TABLE cs_objects (
    id INTEGER PRIMARY KEY,
    bucket_id INTEGER NOT NULL REFERENCES cs_buckets (id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    tenant_id INTEGER NOT NULL REFERENCES cs_tenants (id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    key TEXT NOT NULL,
    size_bytes INTEGER NOT NULL,
    sha256 BLOB NOT NULL,
    content_type TEXT NOT NULL DEFAULT 'application/octet-stream',
    metadata_json TEXT NOT NULL DEFAULT '{}',
    blob_id INTEGER REFERENCES cs_blobs (id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE (bucket_id, key)
);
CREATE INDEX cs_objects_tenant ON cs_objects (tenant_id, bucket_id);

-- Append-only by API (the store exposes insert + scoped read only).
-- detail_json carries figures and refs — never secrets, never tokens.
CREATE TABLE cs_audit_log (
    id INTEGER PRIMARY KEY,
    ts TEXT NOT NULL,
    tenant_id INTEGER,
    actor_kind TEXT NOT NULL CHECK (actor_kind IN ('operator', 'login', 'system')),
    actor_ref TEXT NOT NULL DEFAULT '',
    action TEXT NOT NULL,
    object_ref TEXT NOT NULL DEFAULT '',
    result TEXT NOT NULL CHECK (result IN ('ok', 'denied', 'error')),
    detail_json TEXT NOT NULL DEFAULT '{}',
    ip TEXT
);
CREATE INDEX cs_audit_tenant ON cs_audit_log (tenant_id, id);

-- CMS content layer (design §13.5): collections are the structure
-- tree; items carry append-only versions; refs link items to items or
-- blobs. These tables are created at schema v2 and exercised by the
-- SF-T12i routes; blob references from cs_content_versions and
-- cs_content_refs count in cs_blobs.refcount (§13.2).
CREATE TABLE cs_collections (
    id INTEGER PRIMARY KEY,
    tenant_id INTEGER NOT NULL REFERENCES cs_tenants (id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    parent_id INTEGER REFERENCES cs_collections (id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    name TEXT NOT NULL,
    slug TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE (tenant_id, slug)
);

CREATE TABLE cs_content_items (
    id INTEGER PRIMARY KEY,
    tenant_id INTEGER NOT NULL REFERENCES cs_tenants (id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    collection_id INTEGER REFERENCES cs_collections (id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    slug TEXT NOT NULL,
    title TEXT NOT NULL DEFAULT '',
    kind TEXT NOT NULL DEFAULT '',
    state TEXT NOT NULL DEFAULT 'draft'
        CHECK (state IN ('draft', 'published', 'archived')),
    current_version_id INTEGER,
    metadata_json TEXT NOT NULL DEFAULT '{}',
    created_by TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE (tenant_id, slug)
);

CREATE TABLE cs_content_versions (
    id INTEGER PRIMARY KEY,
    item_id INTEGER NOT NULL REFERENCES cs_content_items (id)
        ON UPDATE CASCADE ON DELETE CASCADE,
    tenant_id INTEGER NOT NULL REFERENCES cs_tenants (id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    version_no INTEGER NOT NULL,
    blob_id INTEGER NOT NULL REFERENCES cs_blobs (id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    note TEXT NOT NULL DEFAULT '',
    metadata_json TEXT NOT NULL DEFAULT '{}',
    created_by TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    UNIQUE (item_id, version_no)
);
CREATE INDEX cs_content_versions_blob ON cs_content_versions (blob_id);

CREATE TABLE cs_content_refs (
    id INTEGER PRIMARY KEY,
    tenant_id INTEGER NOT NULL REFERENCES cs_tenants (id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    from_item_id INTEGER NOT NULL REFERENCES cs_content_items (id)
        ON UPDATE CASCADE ON DELETE CASCADE,
    to_item_id INTEGER REFERENCES cs_content_items (id)
        ON UPDATE CASCADE ON DELETE CASCADE,
    to_blob_id INTEGER REFERENCES cs_blobs (id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    kind TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    CHECK ((to_item_id IS NOT NULL AND to_blob_id IS NULL)
        OR (to_item_id IS NULL AND to_blob_id IS NOT NULL))
);
CREATE INDEX cs_content_refs_blob ON cs_content_refs (to_blob_id);
