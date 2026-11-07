-- Sample OpenCode database for demos. Invented content only.
CREATE TABLE project (id TEXT PRIMARY KEY, worktree TEXT NOT NULL, name TEXT,
    time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, sandboxes TEXT NOT NULL);
CREATE TABLE session_v2 (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, workspace_id TEXT,
    parent_id TEXT, slug TEXT NOT NULL, directory TEXT NOT NULL, title TEXT, version TEXT NOT NULL,
    metadata TEXT, model TEXT, agent TEXT, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL,
    time_archived INTEGER);
CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, type TEXT NOT NULL,
    seq INTEGER NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
CREATE TABLE session_part (message_id TEXT NOT NULL, session_id TEXT NOT NULL, ordinal INTEGER NOT NULL,
    type TEXT NOT NULL, call_id TEXT, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL,
    data TEXT NOT NULL, PRIMARY KEY (message_id, ordinal));
CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT, workspace_id TEXT, parent_id TEXT,
    slug TEXT NOT NULL, directory TEXT NOT NULL, path TEXT, title TEXT NOT NULL, version TEXT NOT NULL,
    metadata TEXT, agent TEXT, model TEXT, time_created INTEGER, time_updated INTEGER);
CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, time_created INTEGER,
    time_updated INTEGER, data TEXT NOT NULL);
CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL,
    time_created INTEGER, time_updated INTEGER, data TEXT NOT NULL);

INSERT INTO project VALUES ('demo-project-billing', '/Users/demo/projects/billing-service', 'billing-service',
    1793000000000, 1793000000000, '[]');

INSERT INTO session_v2 (id, project_id, parent_id, slug, directory, title, version, metadata, model, agent, time_created, time_updated)
VALUES ('ses_demo_invoices', 'demo-project-billing', NULL, 'invoice-schema', '/Users/demo/projects/billing-service',
        'Move invoices to the new schema', '2.1.4', NULL,
        '{"id":"claude-opus-demo","providerID":"anthropic"}', 'build', 1793100000000, 1793100900000);

INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES
 ('msg_demo_u1', 'ses_demo_invoices', 'user', 0, 1793100000100, 1793100000100,
  '{"text":"Move invoices to the new schema. Keep the old column names readable for one release.","files":[],"agents":[]}'),
 ('msg_demo_a1', 'ses_demo_invoices', 'assistant', 1, 1793100010000, 1793100010000,
  '{"model":{"id":"claude-opus-demo","providerID":"anthropic"},"content":[{"type":"text","text":"I will add a migration that copies the columns and keeps views for the old names."},{"type":"tool","id":"call_demo_1","name":"read","executed":false,"state":{"status":"completed","input":{"path":"migrations"},"content":[{"type":"text","text":"0007_invoices.sql\n0008_indexes.sql"}]}}]}'),
 ('msg_demo_a2', 'ses_demo_invoices', 'assistant', 2, 1793100060000, 1793100060000,
  '{"model":{"id":"claude-opus-demo","providerID":"anthropic"},"content":[{"type":"text","text":"Migration 0009 is written, and the views keep the old names working."}]}');
